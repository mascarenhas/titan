# The lexer and the parser

Titan uses one scannerless [LPegLabel](https://github.com/sqmedeiros/lpeglabel)
parser, written with `relabel`. `titan-compiler/lexer.lua` supplies token
patterns and `titan-compiler/parser.lua` combines them with ordinary captures
and fold captures. There is no separate token stream, whole-source generic
scanner, or speculative type parser. The [language grammar](../language/grammar.md)
defines the surface language; [AST and typedecl](ast-typedecl.md) describes its
representation.

`parser.parse(filename, input)` returns a dense list of top-level AST nodes or
`false, {label = name, loc = location}`. It consumes the complete input and, on
success, attaches LDoc comments through `documentation.attach` (see
[documentation metadata](documentation-comments.md)). The driver parses
folder-module contributors separately, then combines their nodes; folder
discovery and cross-file ordering do not belong to this parser.

## One grammar, no token stream

The parser copies every exported lexer pattern and AST constructor into its
`defs` table, so a grammar action `-> TypeArray` calls `ast.TypeArray`
directly. Uppercase token rules wrap the raw patterns with trailing whitespace
and comments, for example `LPAREN <- %LPAREN SKIP*`. The program consumes
leading whitespace and requires EOF after its optional final module
initializer.

A **terminal** in the grammar is a lexical token, regardless of the number of
bytes in its spelling. A long string or comment is scanned as one lexical unit;
this is distinct from looking ahead through an expression or type.

## Longest match by construction

The `keywords` table in `lexer.lua` lists the reserved words; each keyword
pattern requires an identifier boundary. `lexer.NAME` accepts ASCII
identifiers except reserved words, while `lexer.ANYNAME` accepts any identifier
and is used in declaration, member, label, and variant positions. The Titan
type words `boolean`, `integer`, `float`, `string`, and `value` have their own
tokens but are not reserved, so `integer` can be a value name. C primitive
words (`CINT`, `CUNSIGNED`, ... in `parser.lua`) are contextual foreign-type
names. `ffi`, `L`, `M`, and `self` are bindings established by checking, not
lexer keywords. `goto` and `finally` are reserved but have no surface
production.

The loop over the `symbols` table in `lexer.lua` excludes, from every symbol,
each longer symbol that has it as a prefix. This makes `<|` and `|>`
(`TYPEOPEN`, `TYPECLOSE`) indivisible generic delimiters alongside `<`, `>`,
comparison operators, shifts, and bitwise `|`.

Three lexical exclusions follow that loop: `lexer.DOT` excludes a dot before a
decimal digit (a numeral), `lexer.LBRACKET` excludes a long-string opener, and
`lexer.SUB` excludes `--` (a comment). `ANYNAME` and the contextual
primitive-word patterns deliberately overlap `NAME`; grammatical context
selects them, not a global lexer priority.

## Lexing numbers and strings

`lexer.NUMBER` matches a deliberately broad candidate and validates it inside a
match-time capture with Lua's `tonumber`; a malformed candidate raises
`MalformedNumber`. The match-time capture returns only a position, so a wide
constructor does not retain one dynamic capture per numeral. The ordinary
capture produces the Lua value afterwards; the parser wraps `NUMBER` in a
string capture to retain the validated spelling as `_numeral`. Its
`ExpInteger`/`ExpFloat` choice follows Lua's numeric tag, while C literal
classification uses the preserved radix and exact digits instead of that value.

Quoted strings decode Lua-style escapes. The decimal-escape pattern only
admits 0–255 (`MalformedEscape_decimal`), `\x` requires exactly two hex digits
(`MalformedEscape_x`), and `\u{...}` rejects code points above U+10FFFF
(`MalformedEscape_u`) before emitting UTF-8. `\z` skips following whitespace,
a backslash-newline becomes a newline, and any other escape raises
`InvalidEscape`; an unescaped newline raises `UnclosedShortString`. Long
strings and long comments match their opening delimiter's `=` level, skip one
leading newline, and do not decode escapes (`UnclosedLongString`). These
delimiter and validation predicates are lexical operations, not syntactic
lookahead over recursive productions.

## Committed alternatives and bounded lookahead

The parser has three mandatory review rules:

1. Every positive or negative syntactic predicate inspects a constant number of
   terminals. It may inspect a bounded convenience helper, but never an
   expression, type, parameter list, block, or complete declaration.
2. Alternatives do not share a prefix containing a syntactic nonterminal.
   Consume that prefix once and choose the suffix from the next terminal.
3. Once a bounded terminal prefix selects an alternative, each syntactic
   nonterminal in that branch carries `^ErrorLabel`. Failure reports the error
   rather than retrying another alternative. Helpers whose entire expansion
   consumes a bounded number of terminals are the exception.

Examples of bounded conveniences are positions/fresh-list captures (zero
tokens), operator/field-separator selectors (one token), modifier selectors,
and declaration-head tests. They must not grow into hidden recursive probes.
FIRST(expression) tests (`EXPSTART`, `LITERALSTART`) inspect token starts; they
do not call the expression parser. A malformed committed string or numeral must
therefore reach its lexical error rather than disappear inside a failed
lookahead.

Declarations sharing `local`, `const`, `foreign`, or `function` are selected by
bounded heads. A module variable is selected by `variablehead`: optional
`local`/`const`, then `ANYNAME` followed by `:` or `=`. Keyword-named variables
therefore do not swallow `record` declarations or `do ... end`. The checker
validates the meaning and visibility of the resulting name.

A `{` in type context consumes one type, then chooses a Map or an Array from
`:` versus `}` (`finish_curly_type`). A `(` consumes one grouped type before
any optional-type suffix. A colon following `function(...)` is greedily a
return annotation (`rettypeopt`): `{function(): T}` is an Array, and
`{(function()): T}` is the disambiguated Map.

Foreign types cannot consume `.`, so `foreign T.new_array(n)` has an explicit
boundary between its foreign type and pseudo-operation. A nested pointer
constructor requires parentheses, as in `foreign *(*int)`. `owned` belongs to
Titan type syntax and takes a complete foreign pointer/array operand. Typedef,
owner eligibility, and foreign-function body restrictions belong to checking.

## Fold captures and expression precedence

Repeated source lists use `~>` fold captures with a fresh accumulator for each
match. They do not expand an unbounded list into Lua function results. Records
and unions return one `Parser.Declarations` bundle that `defs.append_program`
flattens; a union with many constructors still contributes one capture, which
keeps `table.unpack` from exhausting LPeg's stack.

The ordinary binary operators use one incremental precedence stack
(`binary_start`, `binary_step`, `binary_finish`, `reduce_binary`) driven by the
`binary_precedence` table. Equal precedence reduces immediately, giving
left-associative comparisons and arithmetic; `..` does not reduce against an
earlier `..`, making it right-associative. This reproduces the language
manual's `e1` through `e10` tiers without ten nested capture wrappers for each
nested expression. `finish_concat` flattens a concatenation chain into one
`ExpConcat`, and `fold_binop_concat_right` folds its maximal trailing run of
string and number literals into one `ExpString`.

Power, unary operators, and `as`/`is` keep their separate syntactic boundary.
`defs.power` collects operands and intervening unary prefixes, then folds from
the right: `a ^ -b ^ -c` means `a ^ (-(b ^ (-c)))`. Unary minus binds outside a
power on its left. `defs.cast_or_test` accepts one `as`/`is` tail; an
additional cast requires parentheses.

Suffixes fold over their receiver in written order. A name or dot/colon
selector can carry explicit type arguments; `call_suffix` moves them into
`ExpCall.typeargs` when a call follows, otherwise they stay as
`_nominal_typeargs` on the candidate for the checker to accept or reject.
Brackets consume the first expression once, then inspect a comma or closing
bracket to distinguish indexing from full/partial ranges.

`LIST_LIMIT` (100) bounds written parameter lists, generic binder and
argument lists (`defs.checklist`), and expression lists
(`defs.check_expression_list`, which admits one extra trailing `...`, spread,
or `...` range). Violations raise `ListTooLong`. Return-type lists have no
parser limit; function type and result capacities are checker- and
coder-owned. Length and shape validation uses ordinary captures and the
parser's private structured syntax failure, not value-retaining match-time
captures.

## Semantic boundaries

`defs.statement_candidate` turns a prefix expression without an assignment
tail into `StatCall`, and one with a tail into `StatAssign` whose `vars` still
hold expressions and whose `_parsed_candidates` is true. The checker validates
both; see
[syntax candidates](checker.md#syntax-candidates-and-semantic-validation). The
parser does not reparse an expression merely to improve these diagnostics.

`defs.adjust_exp` wraps a parenthesized call, `...`, spread, or subset in
`ExpAdjust` and marks every parenthesized result `_parenthesized`, so the
checker can reject it as an assignment target.

Bare `...` is syntactically an expression. A following `[` selects its
index/range suffix (`ExpDotsIndex` or `ExpSubset`); otherwise a token in
FIRST(expression) commits `defs.dots_or_spread` to an `ExpSpread` subject. Other
following tokens leave `ExpDots`. `#...` is its own `ExpDotsLen` atom, so
`#... - 1` differs from the spread `... - 1`. Spread placement and adjustment
are checker rules; see [spread expressions](spread-expressions.md).

## Parse-time desugarings

- `defs.recorddecl` adds an adjacent synthesized `new` static after each record
  ([record constructors](record-constructors.md#declaration-staging-and-call-lowering)).
- `defs.uniondecl` adds one adjacent positional constructor static per variant
  ([unions](unions.md#ast-and-parser-lowering)).
- `parser.normalize_import` maps short standard-library import names through
  `standard_imports` to their `titan.*` logical names, and strips a terminal
  `.titan` marker into `TopLevelImport.source_required`.
- `lower_defers`, called from `defs.simpleblock`, lowers each `defer` within its
  statement list into a `StatTry` whose body is the remaining suffix and whose
  `finallyblock` is the deferred statement. Later statements are appended into
  that nested tail list, so the suffix is never copied. The nodes carry
  `_defer_tail`. This preserves LIFO cleanup, block boundaries, catch/rethrow
  behavior, and source locations. See
  [error handling](error-handling.md#frontend-representation) for the semantics.

## The error-label system

### Raising a label

`nonterminal^Label` commits that parse; `%{Label}` raises a label directly. Every
referenced name must appear in `syntax_errors.errors`. The public label/location
contract also covers ordinary-capture validation failures, such as an overlong
list or an optional annotation applied to a multiple-result shape; these raise
through the private `syntax_failure` helper.

### From label to message

`parser.error_to_string` formats `syntax error: <message>` through
`location.format_error`. Preserve a location at the relevant token or missing
component. An arbitrary Lua exception in a capture remains an exception; it
must not be mistaken for a user syntax error.

### Adding a new labeled error

Add the registry entry and a focused invalid-source test. Prove that a branch
has been selected by a terminal before making its recursive component committed.
Test nearby valid alternatives, not only the newly rejected input.

## Location tracking

`P <- {} -> get_loc` is an ordinary position capture. `defs.get_loc` interns
one immutable location per byte position in the per-parse `SOURCE_LOCATIONS`
table, built by `location.from_pos`. `titan-compiler/location.lua` caches each
source string's newline offsets in `newline_cache` and binary-searches them to
produce one-based lines and byte columns. Name, module, owner, end, and
structural locations are preserved for diagnostics and language-server
consumers.

Ordinary captures avoid retaining one dynamic LPeg result per source location,
and the lexer separates value production from match-time validation. Wide flat
inputs must not overflow the dynamic capture-result limit merely because there
are many tokens; deeply nested syntax remains a separate grammar-depth
consideration.

## Non-reentrancy

The parser is non-reentrant. `parser.parse` asserts that no parse is active,
installs `THIS_FILENAME`, `SOURCE_TEXT`, and a fresh `SOURCE_LOCATIONS`,
executes the match under `pcall`, and clears all three on success, labeled
failure, structured capture failure, and unexpected Lua error. It converts only
its private `SYNTAX_FAILURE` marker to the public syntax-error result; other
errors are rethrown. No source or location state may leak into the next parse.

## Testing parser changes

`spec/lexer_spec.lua` and `spec/parser_spec.lua` own token, AST, label, source
location, associativity, commitment, and deterministic scaling regressions.
Use instruction/capture growth checks rather than wall-clock thresholds. Cover
large declaration/constructor lists, very wide unions, nested calls/indexes,
malformed committed suffixes, and failure followed by another parse.

Checker tests own invalid lvalues, non-call statements, alias categories, and
spread placement. Coder tests own their runtime consequences. Green tests alone
do not prove bounded lookahead or committed parsing: a review must inspect every
changed predicate and alternative against the rules above.
