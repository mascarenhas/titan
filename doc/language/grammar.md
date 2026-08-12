# The Titan grammar

This chapter is the reference grammar of Titan as implemented by the
0.23 prototype compiler: lexical conventions, the complete syntactic
grammar, operator precedence, and the restrictions the EBNF alone does
not show. It replaces the old manual's stale grammar.

The notation is extended BNF, as in the Lua manual: `{A}` means zero or
more As, `[A]` an optional A, and `|` separates alternatives. Keywords
and quoted symbols (`'('`) are terminals; **Name**, **NamedLabel**, **CName**,
**Numeral**, and **LiteralString** are the lexical categories defined below.
Whitespace and comments may appear between any two tokens. A source file must parse
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
and       as      boolean  break     case    catch   const   defer  do      else
elseif    end     false    finally   float   for     foreign function
goto      if      import   in        integer interface is    local   nil
not       or      owned    raise     record  repeat  return  string  then
true      type    union    until     value   when    while
```

`in` is used by the generic `for ... in` statement. `goto` is still
reserved but unused, and `::` is recognized by the lexer but used by no
grammar rule — there are no labels. (`break` *is* a statement — see
[statements](statements.md#break-no-goto).) The type keywords `boolean`,
`float`, `integer`, `nil`, `string`, and `value` are reserved too, so
they cannot name variables, functions, or fields (`local integer:
integer = 10` is a syntax error).

A **NamedLabel** has the same raw ASCII spelling as a Name but does not exclude
reserved words. It is used only immediately before `=` in a named call's brace
list, so `f { repeat = 1 }` is legal without making `repeat` a legal variable,
declaration, or record-field name.

A **CName** has the same raw spelling and is accepted only in a contextual
qualified member/type position that the checker resolves through a C
`foreign import`. This permits C symbols named `when`, `type`, `interface`,
`repeat`, or another Titan keyword without making those spellings legal
ordinary Titan identifiers.

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

A flat Titan source, or each independently parsed file of a
[folder module](folder-modules.md), is a sequence of top-level declarations.
The canonical source may end with one root `do ... end` module initializer;
for a folder module only its main source may contain that initializer. Its `block` may use the ordinary optional `catch` trailer.

```
program  ::= {tldecl} [moduleinit]
tldecl   ::= tlmethod | tlrecfunc | tlfunc | tlforeignfunc | tlvar
           | tlrecord | tlunion | tlinterface | tltype | tlimport
           | tlforeignimport
tlmethod ::= [local] function Name ':' Name '(' [parlist] ')' [':' rettype] block end
tlrecfunc ::= [local] function Name '.' Name '(' [parlist] ')' [':' rettype] block end
tlfunc   ::= [local] function Name '(' [parlist] ')' [':' rettype] block end
tlforeignfunc ::= foreign function Name '(' [parlist] ')' [':' rettype] block end
tlvar    ::= [local] decl '=' exp
tlrecord ::= [local] record Name {recordfield} end
tlunion  ::= [local] union Name unionvariant {unionvariant} end
tlinterface ::= interface Name interfacemethod {interfacemethod} end
interfacemethod ::= function Name '(' [parlist] ')' [':' rettype]
tltype   ::= [local] type Name '=' type
recordfield     ::= [local] Name ['?'] ':' type [';']
unionvariant    ::= [local] Name [':' type] [';']
tlimport        ::= local Name '=' import importname
tlforeignimport ::= local Name '=' foreign import importname
moduleinit     ::= do block end
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
interface Movable
    function move(dx: float, dy: float)
end
version = "0.5"                      -- exported module variable, inferred
function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end
function Point.origin(): Point
    return Point.new(0.0, 0.0)
end
do
    origin_x = Point.origin().x        -- optional final module initializer
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
* A `union` must contain at least one variant and synthesizes one
  positional-only static constructor per variant. An empty variant takes no
  parameter; a payload variant takes one. See [Unions](unions.md).
* An `interface` is a nonempty, public, top-level type declaration. Its
  body contains bodyless `function` signatures only: there is no `local`
  Interface, nested Interface, method body, receiver colon, field, static, or
  member-level `end`. See [Interfaces](interfaces.md).
* A module variable's initializer is a full expression; after `=`, the
  keywords `import` and `foreign import` mark an import instead.
* The optional `moduleinit` is the sole executable root construct. It runs
  once per Lua state after all logical-module declarations, including folder
  contributors, and must remain last.

## Declarations and types

```
decl       ::= Name ['?'] [':' type]
decllist   ::= decl {',' decl}
qualifiedtype ::= Name '.' Name
automaticlocaldecl ::= Name ':' qualifiedtype ['[' ['-'] Numeral ']']
type       ::= simpletype
            |  funargtypes '->' rettype
            |  simpletype '->' rettype
simpletype ::= basictype ['?']
basictype  ::= nil | boolean | integer | float | string | value
            |  Name '.' Name
            |  '*' simpletype
            |  const '*' simpletype
            |  ownedtype
            |  Name
            |  '{' type ':' type '}'
            |  '{' type '}'
ownedtype  ::= owned '*' cownedpayload
            |  owned cownedpayload '[' ']'
cownedpayload ::= nil | boolean | integer | float | string | value
            |  Name '.' Name
            |  '*' cownedpayload
            |  const '*' cownedpayload
            |  Name
            |  ownedtype
funargtypes::= '(' [type {',' type} [',' varargtype] | varargtype] ')'
varargtype ::= '...' ':' type
resulttypes::= '(' [type {',' type} [',' flexrettype] | flexrettype] ')'
flexrettype::= '...' ':' type
rettype    ::= funargtypes '->' rettype
            |  simpletype '->' rettype
            |  resulttypes
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
write `p: T?`. Record fields admit the annotated shorthand `x?: T`, which is
equivalent to `x: T?`.

In types, `Name` may be a record, union, Interface, or transparent alias, and
`mod.Name` may name an exported one from an imported module; `{T}` is an
array, `{K: V}` a map, `T?` an option type, and `t -> t` a function type. A
function type may end its argument list with
`...: T` to describe a variadic function value, and a parenthesized result
list may end with `...: T` to describe a flexible result run. The two tails
are independent. When a fixed result prefix is present, a comma is required
before the tail: `(integer, ...: string)` is valid, while
`(integer ...: string)` is not. `->` is right-associative (`a -> b -> c` is
`a -> (b -> c)`) and binds tighter than the commas of an enclosing
parenthesized result list.

`owned *mod.T` is the scalar GC-owner spelling and `owned mod.T[]` is
the dynamically counted owner spelling. The first `*` of the scalar form is
the ownership marker, so another pointer layer belongs to the payload:
`owned **mod.T` owns one `mod.T *`, while `owned *mod.T[]` owns an array of
`mod.T *`. `cownedpayload` is optionless so the one trailing `?` accepted by
`simpletype` wraps the complete owner. The parser accepts the shared payload
shape above; the checker then requires a complete, allocatable imported C
object type and rejects Titan, `void`, function, incomplete, fixed-array
typedef, and nested-owner payloads. A flexible-array-member struct is a scalar
owner allocated through its special `.new(count)` constructor. A numeral
between the brackets is not owner syntax.

A bare `resulttypes` form is valid only in
`rettype` position — a function's return annotation or the right side
of `->` — which is how multiple and flexible return types are written:

```lua
function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end
function stream(): (boolean, ...: string)
    return true
end
local maybe: integer? = nil                  -- option type
local grid: {{float}} = {}                   -- array of arrays
local ages: {string: integer} = {}           -- map
```

The `?` suffix attaches only to `simpletype`, so it cannot be applied directly
to a function type: `((integer) -> integer)?` is a syntax error. The type
system does support options of functions; name the function type with an alias
and suffix the name instead, for example `type F = (integer) -> integer`
followed by `local f: F? = nil`.

`foreign (P...) -> R` is a C function-pointer type, not an ordinary Titan
function type; `()` on its right means C `void`. A top-level `foreign function`
uses the same restricted C signature and body described in
[Foreign functions](foreign-functions.md).

Function types are valid, checked types in any type position: functions
are first-class values, so a function type may annotate a variable,
parameter, return, field, or any other declaration, and a function value
inhabiting it can be stored, passed, returned, and called. A return list
of `()` denotes a function that returns nothing, distinct from `nil`
(one `nil` return). A flexible tail must be last, appear inside the
parenthesized result list, and include its element type. `->` is
right-associative and function types nest, so
a higher-order type like `(integer -> integer, integer) -> integer` is
written directly. See [the type system](types.md#function-types).

## Statements

```
block      ::= simpleblock ['catch' simpleblock]
simpleblock::= {statement} [returnstat]
statement  ::= ';'
            |  do block end
            |  while exp do block end
            |  repeat block until exp
            |  if exp then block {elseif exp then block} [else block] end
            |  case exp casearm {casearm} [else block] end
            |  for decl '=' exp ',' exp [',' exp] do block end
            |  for decllist in explist do block end
            |  local automaticlocaldecl
            |  local decllist '=' explist
            |  varlist '=' explist
            |  functioncall
            |  break
            |  raise [exp]
            |  defer statement
returnstat ::= return [explist] [';']
casearm    ::= when Name [':' Name] then block
varlist    ::= var {',' var}
explist    ::= exp {',' exp} [',' '...']
            |  '...'
var        ::= Name
            |  prefixexp {suffix} '[' exp ']'
            |  prefixexp {suffix} '.' Name
```

A `case` must contain at least one `when` arm. Every arm and its optional
`else` consumes a full `block`, so each may have its own `catch`; a `defer` inside that block is transformed normally. The checker
requires a union scrutinee, rejects duplicate arms and binding an empty
variant, but does not require exhaustive coverage. See
[Unions](unions.md#case-statements).

An lvalue (`var`) is a plain name or a suffixed expression whose *last*
suffix is an index or a field selection — `f()[1] = v`, `m[k][1] = v`,
and `f().x = v` are assignable, as is reading `f().x`; a bare call is
not. Multiple assignment and multiple initialized `local`
declarations mirror Lua. The one no-initializer production is restricted to a
single qualified C type (optionally with one source-written extent), such as
`local options: c.Options` or `local storage: c.Item[3]`; the checker then
requires an eligible complete C aggregate and a positive integer extent. See
[C FFI declarations and expressions](c-ffi-expressions.md). Any other local
declaration requires an initializer, so plain `local x: integer` is a syntax
error. `return`
takes zero or more expressions, only as the last statement of a block.
In a zero-return function (`(...) -> ()`), a bare `return` returns zero
values. Written return expressions are evaluated but their values are
discarded, so `return nil` also exposes zero results there. In an explicit
`: nil` function, a bare `return` is accepted as the one `nil` return. In
option- or `value`-returning functions, write `return nil` explicitly.

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
e11         ::= castexp
castexp     ::= unopexp [(as | is) type]
unopexp     ::= {unop} e12
e12         ::= simpleexp ['^' e11]
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
suffix      ::= callargs
             |  ':' Name [callargs]
             |  '[' exp ']'
             |  '.' Name
functioncall ::= prefixexp {suffix} callargs
              |  prefixexp {suffix} ':' Name callargs
callargs    ::= funcargs | namedargs
funcargs    ::= '(' [explist] ')'
             |  LiteralString
namedargs   ::= '{' [namedarglist] '}'
namedarglist ::= namedarg {fieldsep namedarg} [fieldsep]
namedarg    ::= NamedLabel '=' exp
constructor ::= '{' [fieldlist] '}'
fieldlist   ::= field {fieldsep field} [fieldsep]
field       ::= exp
             |  '...'
             |  Name '=' exp
             |  '[' exp ']' '=' exp
fieldsep    ::= ',' | ';'
```

Parentheses and bare strings are positional call syntax: `f(x)` and
`f "literal"`, with corresponding method forms. Bare braces are always named
syntax, including `{}` and regardless of whitespace: `f { x = 1 }`,
`f{x = 1}`, and `o:m{}`. A constructor passed as one positional argument must be
parenthesized, as in `f({1, 2})`, `f({x = 1})`, or `f({})`. Named lists accept
only `NamedLabel = exp`; positional fields, computed keys, `...`, and mixtures
are syntax errors. A method name used in a `suffix`/`callargs` position is a
call; a method name with **no** following `callargs` — a bare `o:m` — is
instead a [bound method reference](closures.md#bound-method-references), a function
value. Constructors cover positional Arrays, Maps (computed `[k] = v` fields
or, for an exact integer key type, all-positional fields), and records
(`name = v`). Positional and keyed forms cannot be mixed; `,` and `;` are
interchangeable and a trailing separator is allowed. A `funcexp` is an
anonymous function: unlike a top-level `tlfunc`, its fixed-parameter and bare
input-`...` annotations are optional, and an omitted complete result annotation
may likewise come from a matching expected function type. Explicit `: ()` fixes
the zero-result shape; without usable context an omitted result annotation also
defaults to zero. Because a `funcexp` is a `simpleexp` and not a `prefixexp`, it
cannot be applied directly —
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
| `as` `is` | postfix on one unary expression; non-associative |
| `not` `#` `-` `~` (unary) | prefix |
| `^` | **right** |

This is Lua's table with a non-chaining `as`/`is` level between
multiplication and unary expressions. As in Lua,
`^` binds tighter than the unary operators on its *left*, while its
right operand may carry them: `-1 ^ -2 ^ 3 * 4` parses as
`(-(1 ^ (-(2 ^ 3)))) * 4`. `as` and `is` bind tighter than the
multiplicative and looser binary operators: `2 + v as integer` is
`2 + (v as integer)`, and `2 + v is integer` is
`2 + (v is integer)`. They wrap unary expressions (`-v is integer` is
`(-v) is integer`). Since `^` recurses through the `e11` level on its right,
`v ^ 2 as integer` is `v ^ (2 as integer)`; write
`(v as integer) ^ 2` when the cast is the left operand, and
`(v ^ 2) is integer` when the whole power is the test operand.
`v is integer ^ 2` is a syntax error. The comparison
operators chain *grammatically* —
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
3. **`catch` is a block trailer.** There is no `try` keyword.
   A block may have a `catch` trailer; its clause body is a `simpleblock`.
4. **`defer` cannot directly defer another `defer`.** The grammar
   production is guarded like `defer !defer statement`, so
   `defer defer cleanup()` is a syntax error. Use two separate defers for
   last-in-first-out cleanup, or `defer do ... end` for multiple cleanup
   statements.
5. **`as` and `is` do not chain.** `x as integer is float` is a syntax
   error; their operand is an `unopexp`, so chaining grammatically
   requires parentheses (`(x as integer) is value`). Which casts/tests are
   then *accepted* is a typing matter ([Expressions](expressions.md)) —
   each parenthesized edge is checked independently. For example,
   `(x as integer) as float` is accepted because the second edge is a written
   numeric conversion, while `(x as integer) as string` is rejected.
6. **Lvalues cannot be parenthesized.** `(x) = 1` is a syntax error
   (`Expected a valid lvalue in the left side of assignment but found
   a regular expression.`).
7. **Every declaration needs an initializer.** Module variables and `local`
   statements require `= explist`, including C aggregates and arrays. The
   declaration-only `module.CType[N]` and `module.CType[]` spellings select a
   fixed automatic array or borrowed view only when initialized directly by
   `.new_array(...)`.
8. **Parenthesizing a call truncates it.** `(f())` adjusts a
   multiple-value call to exactly its first value, as in Lua. See
   [Functions](functions.md).
9. **Record constructors needing a type from context is a typing rule,
   not a syntax rule.** The grammar places `constructor` wherever any
   expression can go; the *type checker* then requires a named-field
   constructor to appear where the expected record type is known,
   reporting `no context to provide type for record constructor`
   otherwise. Array and computed-key Map constructors can instead have their
   types inferred from their elements. A positional constructor defaults to
   Array and needs an exact `{integer: V}` context to construct a Map. See
   [Records](records.md) and
   [Arrays and maps](arrays-maps.md).
