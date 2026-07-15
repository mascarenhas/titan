# The Titan grammar

This chapter is the reference grammar of Titan as implemented by the
0.12 prototype compiler: lexical conventions, the complete syntactic
grammar, operator precedence, and the restrictions the EBNF alone does
not show. It replaces the old manual's stale grammar.

The notation is extended BNF, as in the Lua manual: `{A}` means zero or
more As, `[A]` an optional A, and `|` separates alternatives. Keywords
and quoted symbols (`'('`) are terminals; **Name**, **Numeral**, and
**LiteralString** are the lexical categories defined below. Whitespace
and comments may appear between any two tokens. A source file must parse
as one complete `program`; trailing text is a compile-time (syntax)
error.

*Implementation note:* this grammar transcribes the scannerless
LPegLabel grammar of `parser.lua` — see
[its internals chapter](../implementation/lexer-parser.md).

## Lexical conventions

### Identifiers and reserved words

A **Name** is any ASCII sequence matching `[A-Za-z_][A-Za-z0-9_]*` that
is not a reserved word. Tokenization is longest-match, so `andy`,
`return17`, and `_end` are names. The reserved words are:

```
and     as      boolean  break     catch   const   defer  do      else
elseif  end     false    finally   float   for     foreign function
goto    if      import   in        integer local   nil     not
or      raise   record   repeat    return  string  then    true
type    until   value   while
```

`in` is used by the generic `for ... in` statement. `goto` is still
reserved but unused, and `::` is recognized by the lexer but used by no
grammar rule — there are no labels. (`break` *is* a statement — see
[statements](statements.md#break-no-goto).) The type keywords `boolean`,
`float`, `integer`, `nil`, `string`, and `value` are reserved too, so
they cannot name variables, functions, or fields (`local integer:
integer = 10` is a syntax error).

### Other tokens

The symbolic tokens are:

```
+   -   *   /   //  %   ^   #   &   ~   |   <<  >>  ..
==  ~=  <   >   <=  >=  =
(   )   [   ]   {   }   ;   :   ,   .   ... ->  ?
```

`->` (function types), `?` (option types), and `...` (variadic
parameters and spreads) are Titan additions. `::` is recognized by the
lexer but used by no grammar rule — there are no labels.

### Comments

A short comment starts with `--` anywhere outside a string and runs to
the end of the line (or of the file). A long comment is `--`
immediately followed by a long-bracket string (see
[string literals](#string-literals)) and may span lines.

```lua
-- a short comment
--[[ a long
     comment ]]
--[==[ a long comment containing ]] safely ]==]
---[[ a SHORT comment: the third '-' defeats the long bracket
```

### Numerals

A **Numeral** has the same written forms as in Lua 5.5:

* decimal integers (`0`, `17`) and hexadecimal integers (`0x1F`);
* decimal floats, with optional fractional part and optional signed
  decimal exponent `e`/`E` (`0.0`, `.5`, `4.`, `1e10`, `1.0e-1`), and
  hexadecimal floats with binary exponent `p`/`P` (`0x1ap2`, `0x1.8p1`).

Whether a numeral denotes an `integer` or a `float` follows Lua's
rules: a fractional part or an exponent makes it a float. There are no
negative numerals — `-1` is unary minus applied to `1`. At the right
edge of a number the Titan lexer consumes the longest run of digits,
letters, dots, and signed exponents and requires the whole run to be a
valid numeral, so `1.2.3`, `1e`, `1e2e3`, and `1337require` are all
malformed numbers (compile-time error `Malformed number.` — Lua 5.5
rejects all four too).

### String literals

A **LiteralString** is a short string or a long string. A *short
string* is delimited by single or double quotes; the closing
quote must match the opening one, and the other quote character may
appear freely inside. An unescaped line break inside a short string is
a compile-time error (`Unclosed short string.`). The escape sequences
are:

| Escape | Produces |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | bell, backspace, form feed, newline, carriage return, horizontal tab, vertical tab |
| `\\` `\'` `\"` | the escaped character itself |
| `\` followed by a real line break | a newline in the string (all four break forms — `\n`, `\r`, `\n\r`, `\r\n` — count as one) |
| `\ddd` | the byte with decimal value *ddd* (one to three digits; value below 256) |
| `\xXX` | the byte with hexadecimal value *XX* (exactly two hex digits) |
| `\u{XXX}` | the UTF-8 encoding of code point *XXX* (one or more hex digits; at most `10FFFF`) |
| `\z` | nothing; skips all following whitespace, including line breaks |

Any other character after a backslash is a compile-time error
(`Invalid escape character in string.`). The decimal escape is greedy
up to three digits (`"\1000"` is byte 100 followed by `0`); a decimal
escape of 256 or more, a `\x` without exactly two hex digits, and a
malformed or out-of-range `\u{...}` are compile-time errors. Titan
enforces the real Unicode ceiling for `\u` — code points above
`U+10FFFF` are rejected — where Lua 5.5 accepts up to `0x7FFFFFFF`.

A *long string* uses *long brackets* — `[[ ... ]]` at level zero,
`[=[ ... ]=]` at level one, and so on with matching `=` counts. No
escape sequences apply, and one line break immediately after the
opening bracket is skipped.

```lua
local s2: string = '\65\x41\u{10FFFF}'    -- "AA" plus a code point
local s3: string = "one \z
                    line"                 -- \z eats the break and indent
local s4: string = [[
no \escapes here]]                        -- value: "no \escapes here"
local s5: string = [==[ contains ]] safely ]==]
```

## Modules and top-level declarations

A Titan source file is a module: a sequence of top-level declarations,
in any order, with no executable statements outside functions.

```
program  ::= {tlmethod | tlrecfunc | tlfunc | tlvar | tlrecord | tltype | tlimport | tlforeignimport}
tlmethod ::= [local] function Name ':' Name '(' [parlist] ')' [':' rettype] block end
tlrecfunc ::= [local] function Name '.' Name '(' [parlist] ')' [':' rettype] block end
tlfunc   ::= [local] function Name '(' [parlist] ')' [':' rettype] block end
tlvar    ::= [local] decl '=' exp
tlrecord ::= [local] record Name {recordfield} end
tltype   ::= [local] type Name '=' type
recordfield     ::= [local] Name ':' type [';']
tlimport        ::= local Name '=' import importname
tlforeignimport ::= local Name '=' foreign import importname
importname      ::= LiteralString | '(' LiteralString ')'
parlist         ::= param {',' param} [',' varargparam]
                 |  varargparam
param           ::= Name ':' type
varargparam     ::= '...' ':' type
```

```lua
local m = import "ext.module"        -- both import forms are accepted
local c = foreign import("stdlib.h")
record Point
    x: float
    y: float
end
local origin_x: float = 0.0          -- local module variable
type Coordinates = {float}           -- exported transparent type alias
version = "0.5"                      -- exported module variable, inferred
function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end
function Point.origin(): Point
    return Point.new(0.0, 0.0)
end
```

Notes on the top level:

* A missing `[':' rettype]` annotation means the function returns
  *nothing* — its type is `(...) -> ()`, the zero-return form, distinct
  from a `: nil` return of one `nil` value (see [Functions](functions.md)).
* Methods and record functions are written outside the `record ... end` body,
  which contains only fields; a record may be empty (`record A end` parses).
  `local` on a record, record field, method, or record function makes that
  declaration visible only inside the defining module.
* A `record` also synthesizes a static constructor `Name.new`, taking
  the fields as positional parameters in declaration order. `Name.new` is
  local when the record is local or any field is local. See
  [Records](records.md).
* A module variable's initializer is a full expression; after `=`, the
  keywords `import` and `foreign import` mark an import instead.

## Declarations and types

```
decl       ::= Name ['?'] [':' type]
decllist   ::= decl {',' decl}
type       ::= simpletype
            |  funargtypes '->' rettype
            |  simpletype '->' rettype
simpletype ::= basictype ['?']
basictype  ::= nil | boolean | integer | float | string | value
            |  Name '.' Name
            |  '*' simpletype
            |  const '*' simpletype
            |  Name
            |  '{' type ':' type '}'
            |  '{' type '}'
funargtypes::= '(' [type {',' type} [',' varargtype] | varargtype] ')'
varargtype ::= '...' ':' type
typelist   ::= '(' [type {',' type}] ')'
rettype    ::= typelist '->' rettype
            |  simpletype '->' rettype
            |  typelist
            |  simpletype
```

The four forms of `decl` mean:

| Written | Meaning |
| --- | --- |
| `x: T` | type is `T` |
| `x?: T` | type is the option type `T?` |
| `x?` | type is inferred from the initializer, then made optional |
| `x` | type is inferred from the initializer |

These forms are accepted wherever a `decl` appears: module variables,
`local` statements, the control variable of a numeric `for`, and each
visible variable of a generic `for`
(`for i: integer = 1, 10 do ... end` and
`for k: integer, v: string in step do ... end` are valid). Function
*parameters* (`param`) must be annotated and admit no `?` shorthand —
write `p: T?`.

In types: `Name` is a record type and `mod.Name` one from an imported
module; `{T}` is an array, `{K: V}` a map, `T?` an option type, and
`t -> t` a function type. A function type may end its argument list with
`...: T` to describe a variadic function value. `->` is right-associative (`a -> b -> c` is
`a -> (b -> c)`) and binds tighter than the commas of an enclosing
`typelist`. A bare parenthesized `typelist` is a valid type only in
`rettype` position — a function's return annotation or the right side
of `->` — which is how multiple return types are written:

```lua
function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end
local maybe: integer? = nil                  -- option type
local grid: {{float}} = {}                   -- array of arrays
local ages: {string: integer} = {}           -- map
```

The `?` suffix attaches only to `simpletype`, so there is no syntax for
an optional function type: `((integer) -> integer)?` is a syntax error.

Function types are valid, checked types in any type position: functions
are first-class values, so a function type may annotate a variable,
parameter, return, field, or any other declaration, and a function value
inhabiting it can be stored, passed, returned, and called. A return list
of `()` denotes a function that returns nothing, distinct from `nil`
(one `nil` return); `->` is right-associative and function types nest, so
a higher-order type like `(integer -> integer, integer) -> integer` is
written directly. See [the type system](types.md#function-types).

## Statements

```
block      ::= simpleblock ['catch' simpleblock] ['finally' simpleblock]
simpleblock::= {statement} [returnstat]
statement  ::= ';'
            |  do block end
            |  while exp do block end
            |  repeat block until exp
            |  if exp then block {elseif exp then block} [else block] end
            |  for decl '=' exp ',' exp [',' exp] do block end
            |  for decllist in explist do block end
            |  local decllist '=' explist
            |  varlist '=' explist
            |  functioncall
            |  break
            |  raise [exp]
            |  defer statement
returnstat ::= return [explist] [';']
varlist    ::= var {',' var}
explist    ::= exp {',' exp} [',' '...']
            |  '...'
var        ::= Name
            |  prefixexp {suffix} '[' exp ']'
            |  prefixexp {suffix} '.' Name
```

An lvalue (`var`) is a plain name or a suffixed expression whose *last*
suffix is an index or a field selection — `f()[1] = v`, `m[k][1] = v`,
and `f().x = v` are assignable, as is reading `f().x`; a bare call is
not. Multiple assignment and multiple `local`
declaration mirror Lua, but a `local` declaration *requires* an
initializer — plain `local x: integer` is a syntax error. `return`
takes zero or more expressions, only as the last statement of a block.
In a zero-return function (`(...) -> ()`), a bare `return` returns zero
values and `return nil` is a type error. In an explicit `: nil` function,
a bare `return` is accepted as the one `nil` return. In option- or
`value`-returning functions, write `return nil` explicitly.

```lua
function demo(xs: {integer}, p: Point): (integer, integer)
    local lo: integer, hi = xs[1], xs[1]   -- multiple declaration
    for i = 2, #xs do                      -- step defaults to 1
        if xs[i] < lo then lo = xs[i]
        elseif xs[i] > hi then hi = xs[i]
        end
    end
    p.x, p.y = 0.0, 0.0                    -- multiple assignment
    while lo < 0 do lo = lo + 10 end
    repeat hi = hi - 1 until hi <= 100
    do p:move(1.0, 2.0) end                -- method call as a statement
    return lo, hi                          -- multiple return values
end
```

## Expressions

The expression grammar is a precedence ladder; each level `eN` binds
tighter than the one above it.

```
exp         ::= e1
e1          ::= e2 {or e2}
e2          ::= e3 {and e3}
e3          ::= e4 {('==' | '~=' | '<' | '>' | '<=' | '>=') e4}
e4          ::= e5 {'|' e5}
e5          ::= e6 {'~' e6}
e6          ::= e7 {'&' e7}
e7          ::= e8 {('<<' | '>>') e8}
e8          ::= e9 ['..' e8]
e9          ::= e10 {('+' | '-') e10}
e10         ::= e11 {('*' | '/' | '//' | '%') e11}
e11         ::= {unop} e12
e12         ::= castexp ['^' e11]
castexp     ::= simpleexp [as type]
unop        ::= not | '#' | '-' | '~'
simpleexp   ::= nil | false | true | Numeral | LiteralString
             |  '...'
             |  '...' '[' exp ']'
             |  constructor | funcexp | suffixedexp | prefixexp
funcexp     ::= function '(' [lambdaparlist] ')' [':' rettype] block end
lambdaparlist ::= lambdaparam {',' lambdaparam} [',' lambdavarargparam]
                |  lambdavarargparam
lambdaparam ::= Name [':' type]
lambdavarargparam ::= '...' [':' type]
prefixexp   ::= Name | '(' exp ')'
suffixedexp ::= prefixexp suffix {suffix}
suffix      ::= funcargs
             |  ':' Name [funcargs]
             |  '[' exp ']'
             |  '.' Name
functioncall ::= prefixexp {suffix} funcargs
              |  prefixexp {suffix} ':' Name funcargs
funcargs    ::= '(' [explist] ')'
             |  constructor
             |  LiteralString
constructor ::= '{' [fieldlist] '}'
fieldlist   ::= field {fieldsep field} [fieldsep]
field       ::= exp
             |  '...'
             |  Name '=' exp
             |  '[' exp ']' '=' exp
fieldsep    ::= ',' | ';'
```

Calls support the same argument sugar as Lua — `f(x)`, `f "literal"`,
`f {1, 2}` — and the method forms `o:m(x)`, `o:m "literal"`, `o:m {}`.
A method name used in a `suffix`/`funcargs` position is a call; a method
name with **no** following `funcargs` — a bare `o:m` — is instead a
[bound method reference](closures.md#bound-method-references), a function
value. Constructors cover arrays (positional fields), maps (`[k] = v`), and
records (`name = v`); `,` and `;` are interchangeable and a trailing
separator is allowed. A `funcexp` is an anonymous function: unlike a
top-level `tlfunc` its parameter annotations are *optional* (inferred when
omitted, as is the whole return annotation), and because it is a
`simpleexp` and not a `prefixexp` it cannot be applied directly —
`(function () … end)(x)` needs the parentheses. See
[Expressions](expressions.md),
[Anonymous functions and closures](closures.md),
[Arrays and maps](arrays-maps.md), and [Records](records.md).

```lua
function build(v: value): string
    local xs: {integer}       = {1, 2, 3,}
    local m: {string: float}  = {["pi"] = 3.14; ["e"] = 2.72}
    local p: Point            = {x = 1.0, y = 2.0}
    local q: Point            = Point.new(1.0, 2.0)
    local n: integer          = v as integer // 2
    return "n = " .. n .. "!"
end
```

## Operator precedence and associativity

From lowest to highest precedence:

| Operators | Associativity |
| --- | --- |
| `or` | left |
| `and` | left |
| `<` `>` `<=` `>=` `~=` `==` | left |
| `\|` | left |
| `~` (binary, exclusive or) | left |
| `&` | left |
| `<<` `>>` | left |
| `..` | **right** |
| `+` `-` (binary) | left |
| `*` `/` `//` `%` | left |
| `not` `#` `-` `~` (unary) | prefix |
| `^` | **right** |
| `as` | non-associative (does not chain) |

This is Lua's table with `as` added at the tightest level. As in Lua,
`^` binds tighter than the unary operators on its *left*, while its
right operand may carry them: `-1 ^ -2 ^ 3 * 4` parses as
`(-(1 ^ (-(2 ^ 3)))) * 4`. `as` binds tighter than every operator:
`2 + v as integer` is `2 + (v as integer)`, and `v as integer ^ 2` is
`(v as integer) ^ 2`. The comparison operators chain *grammatically* —
`a < b < c` parses as `(a < b) < c` — and are then rejected by the type
checker (compile-time error: `left hand side of relational expression
is a boolean instead of a number`).

## Syntactic restrictions and notes

Some properties are easy to miss in the EBNF, and one frequently
confused rule is not syntax at all:

1. **Only calls can be statements.** A `functioncall` (including a
   method call) is the only expression form allowed in statement
   position; anything else is a compile-time syntax error (`Expected a
   statement but found an expression that is not a function call.` —
   though when the expression *starts* with a valid lvalue, as in
   `x + 1`, the parser commits to an assignment and reports `Expected
   '=' after variable.` instead).
2. **`return` only at the end of a block.** As in Lua, `returnstat` is
   the optional final element of `simpleblock`; a statement after `return`
   (even another `return`) is a syntax error.
3. **`catch`/`finally` are block trailers.** There is no `try` keyword.
   A block may have a `catch`, a `finally`, or both in that order; the
   clause bodies are `simpleblock`s so an inner catch cannot consume an
   outer finally.
4. **`defer` cannot directly defer another `defer`.** The grammar
   production is guarded like `defer !defer statement`, so
   `defer defer cleanup()` is a syntax error. Use two separate defers for
   last-in-first-out cleanup, or `defer do ... end` for multiple cleanup
   statements.
5. **`as` does not chain.** `x as integer as float` is a syntax error;
   the cast operand is a `simpleexp`, so chaining grammatically
   requires parentheses (`(x as integer) as value`). Which casts are
   then *accepted* is a typing matter ([Expressions](expressions.md)) —
   the checker rejects `(x as integer) as float`, for instance, with
   `cannot cast 'integer' to 'float'`.
6. **Lvalues cannot be parenthesized.** `(x) = 1` is a syntax error
   (`Expected a valid lvalue in the left side of assignment but found
   a regular expression.`).
7. **Declarations need initializers.** Both module variables and
   `local` statements require `= explist`.
8. **Parenthesizing a call truncates it.** `(f())` adjusts a
   multiple-value call to exactly its first value, as in Lua. See
   [Functions](functions.md).
9. **Record constructors needing a type from context is a typing rule,
   not a syntax rule.** The grammar places `constructor` wherever any
   expression can go; the *type checker* then requires a named-field
   constructor to appear where the expected record type is known,
   reporting `no context to provide type for record constructor`
   otherwise. Array and map constructors can instead have their types
   inferred from their elements. See [Records](records.md) and
   [Arrays and maps](arrays-maps.md).
