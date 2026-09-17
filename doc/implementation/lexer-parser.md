# The lexer and the parser

Titan uses one scannerless [LPegLabel](https://github.com/sqmedeiros/lpeglabel)
parser, written with `relabel`. `lexer.lua` supplies token patterns and
`parser.lua` combines them with ordinary captures and fold captures. There is
no separate token stream, whole-source generic scanner, or speculative type
parser. The [language grammar](../language/grammar.md) defines the surface
language; [AST and typedecl](ast-typedecl.md) describes its representation.

`parser.parse(filename, input)` returns a dense list of top-level AST nodes or
`false, {label = name, loc = location}`. It consumes the complete input. The
driver parses folder-module contributors separately, then combines their nodes;
folder discovery and cross-file ordering do not belong to this parser.

## One grammar, no token stream

The parser copies exported lexer patterns and AST constructors into its `defs`
table. Uppercase token rules wrap the raw patterns with trailing whitespace and
comments, for example `LPAREN <- %LPAREN SKIP*`. The program consumes leading
whitespace and requires EOF after its optional final module initializer.

A **terminal** in the grammar is a lexical token, regardless of the number of
bytes in its spelling. A long string or comment is scanned as one lexical unit;
this is distinct from looking ahead through an expression or type.

## Longest match by construction

Reserved words require an identifier boundary. `NAME` accepts ASCII identifiers
except reserved words, while `ANYNAME` also accepts reserved-word spellings in
selected declaration, member, and label positions. Primitive Titan type words
are contextual: `integer` can be a value name even though its type-position
pattern denotes the primitive. C type words are contextual foreign-type names.
`ffi`, `L`, `M`, and `self` are bindings established by checking, not lexer
keywords.

The symbolic-token builder excludes every longer symbol sharing a shorter
symbol's prefix. This includes `<|` and `|>` as indivisible generic delimiters,
alongside `<`, `>`, comparison operators, shifts, and bitwise `|`. Function
arrows are no longer a token or a type constructor.

Three lexical exclusions remain necessary: a dot before a decimal digit starts
a numeral, a bracket with a long-string opener starts a string, and `--` starts
a comment rather than subtraction. `ANYNAME` and contextual primitive-word
patterns deliberately overlap `NAME`; they are selected by grammatical context,
not by a global lexer priority.

## Lexing numbers and strings

Numeral recognition consumes a deliberately broad candidate and validates it
with Lua's `tonumber`; malformed candidates report `MalformedNumber`. Ordinary
captures produce the integer or float value after validation. Validation-only
match-time captures return no dynamic values, avoiding a retained runtime
capture per numeral in a wide constructor.

Quoted strings decode Lua-style escapes. Decimal escapes remain bounded to
0–255, hexadecimal escapes require two digits, and Unicode escapes validate the
code-point range up to U+10FFFF before the ordinary conversion capture emits UTF-8.
Backslash-newline, whitespace-eating `\z`, and invalid-escape labels retain their
existing behavior. Long strings and long comments match their opening delimiter's
equals level and do not decode escapes. Delimiter/validation predicates are
lexical operations, not syntactic lookahead over recursive productions.

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
FIRST(expression) tests inspect token starts; they do not call the expression
parser. In particular, a malformed committed string or numeral must reach its
lexical error rather than disappear inside a failed lookahead.

Declarations sharing `local`, `const`, `foreign`, or `function` are selected by
bounded heads. A module variable has a name followed by `:` or `=`, so
keyword-named variables do not swallow `record` declarations or `do ... end`.
The checker validates the meaning and visibility of the resulting name.

A `{` in type context consumes one first type, then chooses an Array or Map from
`}` versus `:`. A `(` consumes one grouped/result shape before validating any
optional-type suffix; it is no longer a possible start of an arrow function
type. A colon following `function(...)` is greedily a return annotation:
`{function(): T}` is an Array, and `{(function()): T}` is the disambiguated Map.

Foreign types cannot consume `.`, so `foreign T.new_array(n)` has an explicit
boundary between its foreign type and pseudo-operation. Another pointer
constructor requires parentheses, as in `foreign *(*int)`. `owned` belongs to
Titan type syntax and takes a complete foreign pointer/array operand. Typedef,
owner eligibility, and foreign-function body restrictions belong to checking.

## Fold captures and expression precedence

Repeated source lists use `~>` fold captures with a fresh accumulator for each
match. They do not expand an unbounded list into Lua function results. Records
and unions return a declaration bundle that the program fold flattens; a union
with many constructors still contributes one capture at that boundary.

The ordinary binary operators use one incremental precedence stack and the
explicit `binary_precedence` table. Reductions reproduce the language manual's
`e1` through `e10` tiers, including left-associative comparisons and arithmetic
and right-associative concatenation. This avoids ten nested capture wrappers
for each genuinely nested expression. Concatenation chains are flattened once
and constant suffixes retain their existing folding behavior.

Power, unary operators, and `as`/`is` retain their separate syntactic boundary.
Power collects its operands and intervening unary prefixes, then folds from the
right: `a ^ -b ^ -c` means `a ^ (-(b ^ (-c)))`. Unary minus binds outside a
power on its left. Written casts/type tests are non-associative; an additional
cast requires parentheses.

Suffixes fold over their receiver in written order. A dot/colon selector can
carry explicit type arguments; subsequent call syntax decides whether it is a
call or a reference candidate. Checking preserves the existing restriction
that explicit callable specialization requires a direct call. Brackets consume
the first expression once, then inspect a comma/closing bracket to distinguish
indexing and full/partial ranges.

The existing parameter, type-argument, and expression-list guardrails remain
separate from genuine nesting and runtime arity limits. Return-type lists retain
their own contract; they must not accidentally inherit a parameter-list cap.
List-length and shape validation use ordinary captures and the parser's private
structured syntax-failure path, not value-retaining match-time captures.

## Semantic boundaries

Assignment and standalone-expression parsing preserve prefix-expression
candidates. `StatAssign._parsed_candidates` tells the checker to validate and
extract lvalues; `StatCall` checking requires an actual call. Parenthesized or
explicitly applied names cannot silently become ordinary assignment targets.
The parser does not reparse the expression merely to improve these diagnostics.

Bare `...` is syntactically an expression. Following `[` selects its index/range
suffix; otherwise a token in FIRST(expression) commits to one full collection
spread subject. Other following tokens leave bare varargs. `#...` retains its
dedicated count atom, so `#... - 1` differs from the spread `... - 1`.

Expression-list and constructor checking classifies vararg ranges as spreads,
rejects non-tail expansion, and preserves parentheses' one-result adjustment.
An adjusted spread owns one evaluated carrier plus an optional first projection;
it participates in read/write flow analysis just like a list-tail carrier.
Ordinary collection subsets without a spread remain invalid scalar expressions.

## Parse-time desugarings

Record declarations retain an adjacent synthesized `new` function. Union
variants written `empty()` or `payload(T)` retain their adjacent positional
constructors and source-order tags. Visibility and constructor markers are
unchanged. Short standard-library imports normalize to their `titan.*` logical
names; the `.titan` source-required marker remains independent of that identity.

`defer` is lowered within its owning statement-list block into nested `StatTry`
nodes with `finallyblock`. The lowering walks the list without repeatedly
copying its remaining suffix. It preserves LIFO cleanup, block boundaries,
catch/rethrow behavior, and source locations. The reserved `finally` keyword
does not introduce a surface clause.

## The error-label system

### Raising a label

`nonterminal^Label` commits that parse; `%{Label}` raises a label directly. Every
referenced name must appear in `syntax_errors.errors`. The public label/location
contract also covers ordinary-capture validation failures such as an overlong
list or an optional annotation applied to a multiple-result shape.

### From label to message

`parser.error_to_string` combines the label's message with
`location.format_error`. Preserve a location at the relevant token or missing
component. An arbitrary Lua exception in a capture remains an exception; it
must not be mistaken for a user syntax error.

### Adding a new labeled error

Add the registry entry and a focused invalid-source test. Prove that a branch
has been selected by a terminal before making its recursive component committed.
Test nearby valid alternatives, not only the newly rejected input.

## Location tracking

`P` is an ordinary position/function capture. It consults the current input and
interns the immutable location by byte position for that parse. `location.lua`
caches newline offsets and uses binary search to produce one-based lines and
byte columns. Name, module, owner, end, and structural locations are preserved
for diagnostics and language-server consumers.

Ordinary captures avoid retaining one dynamic LPeg result per source location.
The lexer likewise separates value production from match-time validation. Wide
flat inputs must not overflow the dynamic capture-result limit merely because
there are many tokens; deeply nested syntax remains a separate grammar-depth
consideration.

## Non-reentrancy

The parser remains non-reentrant. `parser.parse` installs its filename, input,
and per-parse location table, executes the match under `pcall`, and clears all
three on success, labeled failure, structured capture failure, and unexpected
Lua error. It converts only its private structured-failure marker to the public
syntax-error result; other exceptions are rethrown. No prior source/location
state may contaminate the next parse.

## Testing parser changes

`spec/lexer_spec.lua` and `spec/parser_spec.lua` own token, AST, label, source
location, associativity, commitment, and deterministic scaling regressions.
Use instruction/capture growth checks rather than wall-clock thresholds. Cover
large declaration/constructor lists, very wide unions, nested calls/indexes,
malformed committed suffixes, and failure followed by another parse.

Checker tests own invalid lvalues, non-call statements, alias categories, and
spread placement. Coder tests own their runtime consequences. The final audit
must inspect every actual predicate and alternative against the rules above;
green tests alone do not prove bounded lookahead or committed parsing.
