# The lexer and the parser

Titan's front end is a single scannerless parser built on
[LPegLabel](https://github.com/sqmedeiros/lpeglabel) (LPeg extended with
*labeled failures*) and its `re`-style grammar notation, `relabel`. There is
no token stream and no separate lexing pass: `titan-compiler/lexer.lua`
defines one LPeg pattern per token and exports them by name, and
`titan-compiler/parser.lua` references those patterns as terminals inside
one `relabel` grammar that goes straight from source text to the AST
described in [AST and typedecl](ast-typedecl.md).
`parser.parse(filename, input)` returns the AST (a dense list of ordinary
toplevel nodes)
or `false, { label = <string>, loc = <location> }`. The user-facing grammar
all of this implements is in the [language reference](../language/grammar.md).
For a [folder module](folder-modules.md), the driver invokes this same function
independently and sequentially for the main and every contributor, then
concatenates their root nodes. The parser itself has no folder, source-unit,
or per-file-namespace concept.

## One grammar, no token stream

`lexer.lua` exports each token as a raw LPeg pattern under an ALLCAPS name
(`lexer.NAME`, `lexer.NUMBER`, `lexer.LPAREN`, ...). The parser copies every
one of them into the grammar's definitions table (`defs[tokname] = tokpat`),
and every AST constructor too (`defs[tag] = cons`). Inside the grammar,
`%NAME` is therefore the lexer pattern itself, and a semantic action like
`-> TopLevelFunc` calls `ast.TopLevelFunc` directly — grammar rules build AST
nodes with no intermediate representation. (The ALLCAPS convention is for
parser-gen's `re`-style grammars, which expect terminals uppercase and
non-terminals lowercase — per the comment atop `lexer.lua`.)

Whitespace is handled once, by hand, at the bottom of the grammar: for every
token there is a wrapper rule of the shape `LPAREN <- %LPAREN SKIP*`, with
`SKIP <- (%SPACE / %COMMENT)`, so every token consumes trailing whitespace
and comments. The start rule, `program`, begins with `SKIP*` (leading
comments work) and ends with `!.` — trailing garbage is a parse failure. Two
synonym rules, `NEG <- SUB` and `BNEG <- BXOR`, let unary minus and unary
`~` reuse the `-` and `~` tokens.

A few tokens get the whitespace wrapper even when they are rarely used.
`break`, `defer`, `in`, `type`, and `DOTS` (`...`) are real syntax; `goto` and `DBLCOLON`
(`::`) remain reserved/recognized but unused, so there is no `goto`
statement or label syntax.

## Longest match by construction

Because the parser tries token patterns directly at arbitrary positions, the
lexer must guarantee the *longest match* property on its own: at any input
position, at most one exported token pattern matches (`spec/lexer_spec.lua`
enforces this at every position its scan visits — see the testing section).
Three layers provide it:

1. **Keywords vs. names.** Each keyword pattern is `P(keyword) * -idrest`, so
   `local` does not match the front of `localx`; and `lexer.NAME` is a
   match-time capture (`lpeg.Cmt`) that matches an identifier and then
   *fails* if it is a keyword — `andy`, `return17` and `_end` are NAMEs.
   `lexer.NAMEDLABEL` and `lexer.CNAME` are contextual exceptions: both
   capture the raw identifier shape without keyword rejection.
   `NAMEDLABEL` is used only before `=` inside a named-call list, while
   `CNAME` is used only for source-nameable C members and qualified C types.
   A header symbol spelled `when`, `repeat`, or `type` therefore remains
   usable without making that spelling an ordinary Titan name. The parser
   stamps the resulting `Ast.VarDot` or `Ast.TypeQualName` with
   `_contextual_c_name`; the checker accepts that marker only after the
   qualifier resolves to the corresponding C context, and the coder emits the
   stored spelling unchanged.

2. **Symbols vs. longer symbols, generically.** A loop at the end of
   `lexer.lua` makes every symbol pattern subtract every longer symbol it is
   a prefix of:

   ```lua
   for tokname, symbol in pairs(symbols) do
       local pat = P(symbol)
       for _ , symbol2 in pairs(symbols) do
           if #symbol < #symbol2 and symbol == string.sub(symbol2, 1, #symbol) then
               pat = pat - P(symbol2)
           end
       end
       lexer[tokname] = pat
   end
   ```

   This keeps `<` from matching the front of `<=` or `<<` with no per-token
   case analysis; a new multi-character symbol added to `symbols`
   automatically fixes all its prefixes.

3. **Three manual exclusions** where a symbol collides with a *non*-symbol
   token, which the generic loop cannot see:

   ```lua
   lexer.DOT      = lexer.DOT      - (P(".") * R("09"))           -- ".5" is a NUMBER
   lexer.LBRACKET = lexer.LBRACKET - (P("[") * P("=")^0 * P("[")) -- long-string opener
   lexer.SUB      = lexer.SUB      - P("--")                      -- comment
   ```

Consequences, all spec-asserted: `---` is one COMMENT; `///` is `IDIV DIV`;
`-->` is a COMMENT but `->-` is `RARROW SUB`; `<==` is `LE ASSIGN`; `..2` is
`CONCAT NUMBER`.

## Lexing numbers: an over-general pattern plus `tonumber`

The number pattern does not encode Lua's numeral syntax. It matches a
deliberately over-general blob — any run of alphanumerics, dots and signed
exponent markers — and delegates validity to Lua:

```lua
local good_number = Cmt(possible_number, function(_, i, s)
    local n = tonumber(s)
    if n then return i, n else return false end
end)
lexer.NUMBER = #number_start * (good_number + T("MalformedNumber"))
```

If `tonumber` accepts the blob, the capture is the *numeric value*; if not,
the label `MalformedNumber` is raised. The over-generality is intentional:
the blob swallows the whole run, `tonumber` rejects it, and `1337require`,
`1e2e3` and `1.2.3.4` are all single `MalformedNumber` errors rather than
surprising token pairs. (A comment in `lexer.lua` worries that real Lua
would lex `1337require` as `1337` then `require`; empirically Lua 5.5's
lexer rejects all three blobs as malformed numbers too, so the outcomes
match Lua.)

Because the capture is already a number, the parser never sees numeral text:
`defs.number_exp` splits the value with `math.type` into `Ast.ExpInteger` or
`Ast.ExpFloat`, so the integer/float distinction is exactly Lua's (`0x1ap2`
is a float, `0x1abcdef` an integer, `4.` the float `4.0`).

## Lexing strings: decoding during the match

Short strings are fully decoded at lex time — the token capture is the
resulting string, not the quoted source. Open and close quotes are named
group captures compared in a `Cmt` over back-captures
(`Cb("open")`/`Cb("close")`), so `"` can close only `"` and `'` only `'`. A
raw newline inside a short string, or end of input, raises
`UnclosedShortString`.

Escapes are processed by substitution-style captures — each escape pattern
produces its replacement directly, as in `(P("n") / "\n")`,
`(linebreak / "\n")` for backslash-newline, or
`C(decimal_escape) / tonumber / string.char` — and the parts are
`table.concat`ed at the end. Three escapes deserve attention.
**Decimal escapes** `\ddd` enforce the "< 256" rule *structurally*:
`decimal_escape` is an ordered choice of digit-range patterns covering
exactly 0–255, plus a final alternative raising `MalformedEscape_decimal`
for the remaining 3-digit values (`"\555"`); like Lua it is greedy up to
three digits, so `"\12340"` is `"{40"`. **Unicode escapes** `\u{XXX}` use a
`Cmt` to enforce the real Unicode range, because the host's `utf8.char`
(Lua 5.5) accepts code points up to 0x7FFFFFFF:

```lua
function(_, pos, digits)
    local n = tonumber(digits, 16)
    if n > 0x10FFFF then return false end
    return pos, utf8.char(n)
end
```

— any malformation (missing brace, empty braces, non-hex digit, out-of-range
value) raises `MalformedEscape_u`. **`\xXX`** requires exactly two hex digits
(`MalformedEscape_x` otherwise); `\z` skips a run of whitespace and produces
nothing; any unknown `\c` raises `InvalidEscape`.

Long strings (`[[...]]`, `[=[...]=]`) match their equals-level the same way
short strings match quotes, do no escape processing, and skip one linebreak
after the opening bracket. Long comments are `--` followed by a long string
(capture dropped) — hence `UnclosedLongString`'s message, "Unclosed long
string or long comment.".

## Grammar organization

The grammar is one `re.compile([[...]], defs)` call, compiled **once at
module load time**: parsing pays no per-call compilation, and a mistake in
the grammar text fails at `require "titan-compiler.parser"`. Every
node-producing production starts with the rule `P <- {} => get_loc`, a
match-time capture that converts the current byte position into a location
table (`defs.get_loc` calls `location.from_pos`); since `loc` is the first
field of every constructor in `ast.lua`, putting `P` first lands the location
in the right positional argument with no extra plumbing.

The top-level `interface` production commits to a nonempty sequence of
bodyless `function` signatures and builds `Ast.TopLevelInterface` plus ordered
`Ast.InterfaceMethod` children. It has dedicated labels for a local/nested or
empty declaration, local methods, missing method names/parentheses/types,
unexpected members, and a missing final `end`. `interface` is a Titan keyword,
but `CNAME` still captures it in contextual C typedef, field/member, and
prototype-parameter positions; this mirrors the other C-legal Titan keywords.
See [Interfaces](interfaces.md#frontend-representation).

### Function result-shape carriers

Fixed and flexible results are parsed separately. `resulttypelist` captures a
dense fixed list plus an optional final `flexrettypeann` (`...: T`), with the
comma before the tail required when a fixed prefix exists. The parser packages
those captures temporarily as:

```lua
{ rettypes = fixed_dense_list, flexrettype = type_node_or_false }
```

`defs.rettypeopt` returns the pair to `TopLevelFunc`, `TopLevelMethod`, and
`TopLevelStatic`; `defs.lambdarettypeopt` additionally preserves whether the
lambda omitted its return annotation. The checker gives that form the ordinary
zero-return default independently of any parameter-inference context. Function-type
nodes carry `argtypes`, `rettypes`, `varargtype`, and `flexrettype` as four
separate fields. No tail sentinel is inserted into either dense list.

The grammar tries `resulttypelist !RARROW` before its arrow alternatives. That
lookahead distinguishes `(...: T)` as a flex-only result list from
`(...: T) -> R` as a function type with an input vararg. A flexible return must
be parenthesized, typed, last, and comma-separated from a fixed prefix;
`FlexRetColon`, `FlexRetType`, `FlexRetLast`, and `FlexRetParens` give those
failures return-specific labels. See
[Flexible returns](flexible-returns.md#parser-carriers-and-disambiguation).

### The precedence ladder

Expression precedence is a ladder of twelve rules, `e1` (loosest, `or`) down
to `e12` (`^`), each consuming the next-tighter level as its operands. Most
levels are left-associative and share one shape and one fold function —
`e9 <- (P {| e10 (op9 e10^OpExp)* |}) -> fold_binop_left` — where
`fold_binop_left` (`parser.lua`) walks the captured list pairwise, building
left-nested `Ast.ExpBinop` nodes. The operator rules capture the operator as
its literal string (`ADD -> '+'`); note `op10`'s `MOD -> '%%'` — `%` is the
`re` escape character so it must be doubled, but the captured string is plain
`"%"`.

| Level | Operators | Shape |
| --- | --- | --- |
| `e1` | `or` | left fold |
| `e2` | `and` | left fold |
| `e3` | `==` `~=` `<` `>` `<=` `>=` | left fold |
| `e4`–`e7` | `\|`, `~`, `&`, `<<` `>>` | left fold |
| `e8` | `..` | **right recursion**, flattened by `binop_concat` |
| `e9`, `e10` | `+` `-`, `*` `%` `/` `//` | left fold |
| `e11` / `castexp` | `as`, `is` | `unopexp (AS type -> ExpCast / IS type -> ExpIs) / unopexp` |
| `unopexp` | unary `not` `#` `-` `~` | `{\| unop* \|} e12`, `fold_unops` innermost-first |
| `e12` | `^` | **right**: `simpleexp (op12 e11)?` via `binop_right` |

The two right-associative operators do not use the list shape:

* `e8 <- (P e9 (op8 e8^OpExp)?) -> binop_concat` recurses into itself on the
  right. `binop_concat` then does two extra things: if the right operand is
  already an `Ast.ExpConcat`, the left operand is pushed onto its front, so
  chained `..` becomes one flat n-ary `ExpConcat`; and if both operands are
  literals (`ExpString`/`ExpInteger`/`ExpFloat`) they are **constant-folded**
  into a single `Ast.ExpString` with Lua's `..` — `"a" .. "b" .. "c"` parses
  as the literal `"abc"`, `x .. 1 .. 2` as `ExpConcat{x, ExpString "12"}`.
  The parser is not a pure syntax mapper; the source comment itself asks
  "Should this go on a separate constant propagation pass?".

* `e12` makes `^` right-associative, and its asymmetric operands (`simpleexp`
  left, `e11` right) reproduce Lua's quirk that `^` binds tighter than unary
  operators on its left while its right operand may carry them:
  `-1 ^ -2 ^ 3 * 4` parses as `(-(1 ^ (-(2 ^ 3)))) * 4`.

`as` casts and `is` type tests sit below the ladder in `castexp`: the subject
is one `unopexp` (so `2 + foo is integer` is
`2 + (foo is integer)`) and the two forms do not chain —
`y as integer is float` is a syntax error. Their keywords have distinct
`AS`/`IS` tokens, and a labeled missing target reports `CastMissingType` or
`IsMissingType` respectively.

The `e11` right operand of `^` may itself contain either form, so
`x ^ 2 is integer` builds `ExpBinop("^", x, ExpIs(2, integer))`. Testing the
whole power requires `(x ^ 2) is integer`; `x is integer ^ 2` does not parse.

### Expression suffixes as closures

Postfix syntax — calls, method calls, indexing, dot access — is a prefix
followed by suffixes: `suffixedexp <- (prefixexp {| expsuffix+ |}) ->
fold_suffixes`. Each `expsuffix` alternative's action (`defs.suffix_funccall`,
`suffix_methodcall`, `suffix_bracket`, `suffix_dot`) does not build a node;
it returns a *closure* from base expression to wrapped expression —
`defs.suffix_bracket(pos, index)`, for instance, returns
`function(exp) return ast.ExpVar(pos, ast.VarBracket(pos, exp, index)) end`.
`fold_suffixes` then applies the closures left to right, so `x()()[2]` builds
`ExpVar(VarBracket(ExpCall(ExpCall(x))))` with correct nesting — left
recursion (which PEGs cannot express) sidestepped without a rebuild loop.
The four call closures preserve their delimiter and receiver choice:
`suffix_funccall` and `suffix_methodcall` produce `ArgsFunc`/`ArgsMethod` from
parentheses or a bare string, while `suffix_namedfunccall` and
`suffix_namedmethodcall` produce `ArgsNamedFunc`/`ArgsNamedMethod` from
`namedargs`. Bare braces are never `funcargs`; a positional constructor must be
inside parentheses (`f({1, 2})`). `namedargs` accepts only
`NAMEDLABEL '=' exp`, with constructor-style comma/semicolon separators and a
trailing separator. The checker later normalizes a valid named node to its
positional `Args*` counterpart; see
[named-argument internals](named-arguments.md).

### Match-time predicates: lvalues and call statements

Two `Cmt` predicates, `defs.exp_is_var` and `defs.exp_is_call`, inspect an
already-built node during the match, accepting it only if its `_tag` is
`Ast.ExpVar` (respectively `Ast.ExpCall`). The `var` rule (assignment
targets) is `(suffixedexp => exp_is_var) -> exp2var`, plus a bare-`NAME`
alternative for unsuffixed names — parse a full suffixed expression, accept
it only if its last suffix produced a variable. The bare parenthesized
lvalue `(x) = 42` is also rejected, though not by the predicate
(parentheses vanish in the AST, so `(x)` *is* an `ExpVar`): `(x)` carries no
suffix, so `suffixedexp` does not match it, and the `NAME` alternative does
not allow parentheses — while the suffixed `(x).f = 1` is a legal
assignment. Likewise the only expression allowed as a statement is
`(suffixedexp => exp_is_call) -> StatCall`. Both predicates fail *without
raising a label*, letting ordered choice fall through to the explicit
`%{...}` throws described below — which is how `(x) = 42` and `1 + 1` in
statement position get specific messages.

## Parse-time desugarings

The parser performs several rewrites that later passes rely on:

* **Type alias declarations are direct.** `[local] type Name = T` is not a
  desugaring: it produces one `Ast.TopLevelTypeAlias` whose `type` field is the
  ordinary type-annotation AST. The checker keeps the declaration out of the
  value namespace and code generation. See [Type aliases](type-aliases.md).

* **`record` declarations produce two toplevels.** `defs.recorddecl` returns
  an `Ast.TopLevelRecord` plus a synthesized `Ast.TopLevelStatic` named
  `new`, whose parameters are the fields in declaration order and whose body
  returns an init list mapping each field to its parameter. So

  ```lua
  record Point
      x: float
      y: float
  end
  ```

  parses as if the programmer had also written
  `function Point.new(x: float, y: float): Point return {x = x, y = y} end` —
  the same `Ast.TopLevelStatic` node that user-declared record functions use,
  and why `Point.new(2, 3)` is positional in field order. `local record` marks
  both the `TopLevelRecord` and synthesized `new`
  local, and any local field also makes `new` local so outside code cannot
  construct private slots positionally.

* **`union` declarations synthesize positional constructors.**
  `defs.uniondecl` returns an `Ast.TopLevelUnion` followed by one
  `Ast.TopLevelStatic` for each source-order `Ast.UnionVariant`. An empty
  variant gets no parameters; a payload variant gets one hidden
  `__union_payload` parameter and returns `Ast.ExpUnionInit`. The static is
  marked `_union_constructor` and `_union_variant`, so the checker can
  distinguish it from a user function and publish `paramnames = false`.
  Consequently `Message.move(value)` is positional and first-class, while
  `Message.move{...}` remains named-call syntax rather than constructor
  sugar.
  Variant-looking type targets add no parser form: local `Message.move` fits
  the ordinary two-component qualified type and is rejected semantically,
  while imported `m.Message.move` has three components and fails the type
  grammar before checking.

* **Record functions share the static node.** A declaration
  `function Point.origin(): Point ... end` parses to `Ast.TopLevelStatic`.
  The parser sets `islocal` when the declaration is written
  `local function Point.origin(...)`.

* **The root module initializer keeps an explicit parser role.** The optional
  final root `do ... end` produces the ordinary `Ast.StatBlock`, or the
  `Ast.StatTry` already used when its block has a `catch` trailer.
  The small `moduleinit` action sets `_module_initializer` and changes the
  node location to the `do` keyword. Folder assembly can therefore remove the
  main initializer and append it after all contributor roots, or report a
  contributor initializer at the construct that is disallowed, without
  guessing from the statement tag or adding an AST tag.

* **`if`/`elseif` chains flatten to a list.** `defs.ifstat` prepends the
  initial condition/block pair to the captured `elseif` clauses, yielding one
  `Ast.StatIf` whose `thens` is a flat list of `Ast.Then` nodes (plus
  `elsestat`, a block or `false`) — not nested ifs.

* **`case` arms are ordinary blocks.** The grammar requires one or more
  `when Name [: binding] then block` arms and an optional `else block`.
  It builds `Ast.StatCase` and `Ast.CaseArm` directly. Each `block` is the
  same production used elsewhere, including its trailing `catch`
  support and the normal recursive `defer` transformation. There is
  no fallthrough-oriented or statement-list-only arm grammar.

* **Numeric and generic `for` share their prefix.** The grammar parses
  `FOR decl` once and then dispatches to `forrest`: `= exp, exp ...` builds
  `Ast.StatFor`, while `in explist do ... end` or `, decl ... in explist`
  builds `Ast.StatForIn`. Keeping the labeled numeric-`=` failure inside
  `forrest` lets malformed numeric loops still report `AssignFor` without
  swallowing valid generic loops.

* **Missing return types default to zero results.** `defs.rettypeopt` turns an
  absent `: rettype` annotation into an empty fixed list and no flexible tail,
  so `function f() end` has `() -> ()`. A written `: nil` remains one fixed
  nil result. For lambdas, `defs.lambdarettypeopt` still records whether syntax
  was absent, but the checker gives both absence and explicit `: ()` the same
  zero-result shape; only missing input annotations consult an expected type.

* **Parenthesized calls become `ExpAdjust`.** `defs.adjust_exp` wraps
  `( f() )` in an `Ast.ExpAdjust` node — "adjust call to just first value" —
  while parentheses around anything else vanish from the AST entirely
  (`((1))` is just `ExpInteger 1`). The complementary `Ast.ExpExtra` node for
  finite result positions after the first is synthesized only by
  [the checker](checker.md), never the parser; runtime-sized flexible tails
  stay on the call's checker decorations rather than becoming parser nodes.

* **Concat flattening and constant folding** (see the ladder section), and
  the **option-mark desugarings**: the type suffix `T?` becomes
  `Ast.TypeOption` immediately (`defs.typeopt`); a declaration `x?: T`
  eagerly wraps its annotation in `TypeOption` while a bare `x?` defers to
  inference (`Decl{type = false, option = true}`, `defs.optiondecl`).

A non-rewrite worth knowing: the numeric `for`'s step is captured as `false`
when omitted; the default step of `1` is synthesized by the checker.

## The error-label system

### Raising a label

A label is raised in one of three ways:

1. **In the lexer**, with `lpeg.T(Label)` as an ordered-choice alternative
   inside a token pattern — e.g. `good_number + T("MalformedNumber")`.
2. **In the grammar**, with relabel's expectation sugar `pattern^Label`: if
   `pattern` fails at that point, `Label` is raised instead of ordinary
   backtracking. This is the pervasive form (`NAME^NameFunc`, `END^EndFunc`,
   `exp^ExpWhile`, ...); placing `^` is choosing where backtracking ends and
   committed error reporting begins.
3. **Explicitly**, with `%{Label}` guarded by a lookahead, for errors that
   ordered choice would otherwise swallow. The statement rule ends with
   `&(exp ASSIGN) %{ExpAssign}` (an expression followed by `=` that did not
   parse as a `varlist`) and, after the `StatCall` alternative,
   `&exp %{ExpStat}` (a non-call expression in statement position); also
   `!RCURLY %{ExpFieldList}` inside `fieldlist`, for `y{42,,}`.

On failure, `grammar:match` returns `nil, label, errpos`; `parser.parse`
converts `errpos` into a location and returns `false, {label, loc}`. A
failure with no specific label gets relabel's default label `fail`, whose
registry message is just "Syntax Error".

### From label to message

`parser.error_to_string(err)` looks the label up in `syntax_errors.errors`
and renders it via `location.format_error` as, e.g.,
`myfile.titan:2:2: syntax error: Expected a valid lvalue in the left side of
assignment but found a regular expression.`

**The registry contract: every label used anywhere — in `lexer.lua` or
`parser.lua`, by any of the three mechanisms — must have an entry in
`syntax_errors.errors`.** There is no fallback: a missing entry makes
`error_to_string` format `nil` (which Lua 5.5's `%s` stringifies rather
than rejecting), so the user sees `file:line:col: syntax error: nil`
instead of a message.

### Quirks to know about

* **`ExpAssign` is defined twice** in `syntax_errors.lua` — once as
  "Expected an expression after '='.", later as "Expected a valid lvalue in
  the left side of assignment...". In a Lua table constructor the later key
  wins, so only the lvalue message survives — yet the label is raised in
  *both* situations, so `x =` (missing right-hand side) gets the misleading
  lvalue message; `spec/parser_spec.lua` asserts the `ExpAssign` label for
  both `x =` and `(x) = 42`.
* **`AssignImport` is unreachable** — both the `import` and `foreign` rules
  need `local NAME =`, but `toplevelvar` is tried first and raises
  `AssignVar` at the missing `=` — and a comment in the table says so. The
  comment on `ImportImport` claims the same, and the `import` rule indeed
  never raises it (`toplevelvar`'s `!(IMPORT / FOREIGN)` only fails quietly)
  — but the `foreign` rule does raise it: `local x = foreign 42` reports
  `ImportImport`.
* Preserved typos: `RParSimpleExp` is `"Expected ')'to match '('."` and
  `RCurlyInitList` the backwards `"Expected '{' to match '}'."` (raised when
  `}` is missing).

### Adding a new labeled error

Raise the label (`pattern^MyLabel`, a lookahead-guarded `%{MyLabel}`, or
`T("MyLabel")` in the lexer); add `MyLabel = "message"` to
`syntax_errors.errors` — mandatory, per the contract above; and add an
`assert_program_syntax_error(program, "MyLabel")` test to the "uses specific
error labels for some errors" block of `spec/parser_spec.lua` (or the label
tests in `spec/lexer_spec.lua`).

## Location tracking

A location is a plain table `{filename, line, col}` (1-based).
`location.from_pos(filename, source, pos)` converts a byte offset via
`location.get_line_number`, which is lazy and cached: the first query for a
given subject string builds a sorted list of the byte offsets of its `\n`s,
stored in a cache declared **weak-keyed** (`__mode = "k"`) — intended to let
source strings be collected, but ineffective: Lua strings behave as values
in weak tables and are never removed, so entries persist for the life of the
module; the line is then a binary search, and
`col = pos - (newlines[line - 1] or 0)`. The laziness covers building the
index — the parser still computes a location *eagerly for every captured
node* through `P`. `location.format_error(loc, fmt, ...)` produces the
standard `file:line:col: ...` prefix used by both syntax and
[checker](checker.md) errors.
Every folder contributor is parsed with its real filename, so these existing
locations survive plain-node concatenation. Cross-file checker diagnostics
can use `location.format` to name the earlier declaration's complete
`filename:line:col` as well as the primary node.

## Non-reentrancy

The grammar cannot thread extra arguments to its actions (the source comment
laments: "If only lpeg.re had Carg..."), so the current filename lives in the
module-global `THIS_FILENAME`, set by `parser.parse` around `grammar:match`
and guarded by `assert(THIS_FILENAME == nil)` on entry. The parser is
therefore **not reentrant**: a recursive or concurrent `parser.parse` trips
the assert. The normal pipeline never nests parses. A folder module's files
are parsed one after another, and all have returned before its one checker
invocation; imported modules are then parsed by the
[driver's loader](driver.md) from inside `checker.checkimport`. A tool parsing
from inside another parse will still hit the guard. `grammar:match` is also not
run protected, so an
error raised inside a semantic action escapes `parse` without restoring
`THIS_FILENAME`, poisoning later calls in the same process.

## Testing parser changes

* **Lexer changes** go through `spec/lexer_spec.lua`, whose harness does not
  parse: it tries every exported token pattern at each token-start position
  as it scans the input,
  asserting both the expected token/capture sequence and the uniqueness
  property — two patterns matching the same position is itself a failure, so
  adding a token that violates longest match is caught here.
* **Parser tests compare AST subsets.** `spec/parser_spec.lua`'s
  `assert_program_ast` runs `restrict(expected, actual)` — recursively
  keeping only the keys present in the expected table — before
  `assert.are.same`. Write expected trees with only the fields you care
  about (`_tag` plus the relevant children); new node fields and decorations
  then never break old tests. Error tests assert labels, via
  `assert_program_syntax_error`.
* **Folder assembly is driver behavior.** Filesystem ordering, main-only
  initializers, privacy blocks, and cross-file locations belong in
  `spec/driver_spec.lua`; the parser specs continue to exercise one input
  string per call and the unchanged AST vocabulary.
* **The `TableFormatLevel` gotcha.** Failing AST comparisons print the
  table, and luassert's print depth is a *global* parameter.
  `parser_spec.lua` raises it to 100 in `setup()` and restores it in
  `teardown()`, but a stray `assert:set_parameter("TableFormatLevel", -1)`
  in the describe body runs at collection time — and printing a
  self-referential post-checker AST at unlimited depth hangs busted.
* **Remember the installed-rock shadow.** Under busted,
  `require "titan-compiler.parser"` resolves to the installed rock, not your
  working tree — re-run `$PREFIX/bin/luarocks make titan-dev-1.rockspec` after
  editing front-end sources, or your changes silently will not be under test
  (see the [implementation index](index.md)).
