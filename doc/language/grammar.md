# The Titan grammar

This chapter specifies Titan's current source syntax. `{A}` means zero or more
As, `[A]` means an optional A, and `|` separates alternatives. Keywords and
quoted punctuation are terminals. Whitespace and comments may separate tokens.
A file must match one complete `program`; trailing text is a syntax error.
The parser uses bounded token lookahead and incremental fold captures; see
[lexer and parser implementation](../implementation/lexer-parser.md).

## Lexical conventions

### Identifiers and reserved words

**Name** matches ASCII `[A-Za-z_][A-Za-z0-9_]*` except reserved words.
**AnyName** has the same spelling and admits reserved words. The latter is used
for top-level declarations, type names, nominal members, dot/colon selectors,
and named fields where surrounding punctuation identifies the role.

The reserved words are:

```text
and     as     break   case    catch   const   defer   do      else
elseif  end    false   finally for     foreign function goto  if
import  in     interface is    local   nil     not     or      owned
raise   record repeat  return  then    true    type    union   until
when    while
```

`goto` and `finally` remain reserved without surface productions. The type words
`boolean`, `integer`, `float`, `string`, and `value` are contextual identifiers,
as are C primitive words in foreign types. Tokenization uses longest match:
`integer_count`, `return17`, and `_end` are names. Contextual type primitives
retain their defined meaning in an unqualified primitive type position.

`ffi` is a readonly builtin term binding for C values, and ordinary declarations
may shadow it. Foreign type lookup has its own unqualified namespace and does
not depend on that binding. Ordinary function/method bodies and the module
initializer also bind readonly `L` to the current Lua-state pointer and `M` to
the current module. `M.member` can select local members and keyword-named
members; body-local type annotations can use `M.Type` despite local or generic
shadows; `M` can be cast to the specified foreign Udata pointer. Methods bind
`self` to their receiver. Foreign function bodies do not receive `L` or `M`.

### Other tokens

```text
+ - * / // % ^ # & ~ | << >> ..
== ~= < > <= >= = <| |>
( ) [ ] { } ; : , . ... ?
```

`<|` and `|>` delimit generic parameters and arguments. `<` and `>` remain
comparison operators. Function types start with `function`; the old arrow
spelling is not accepted. There is no unary pointer-dereference operator;
write `pointer[0]`.

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

## Modules and declarations

Each source file contains declarations and at most one final initializer.
Folder modules parse each contributor independently; only the main source may
contain the final initializer. See [folder modules](folder-modules.md).

```text
program ::= {tldecl} [moduleinit]
tldecl ::= tlmethod | tlstaticfunc | tlfunc | tlforeignfunc | tlvar
         | tlrecord | tlunion | tlinterface | tltype | tlforeigntype
         | tlimport | tlforeignimport | ';'
tlmethod ::= [local] function AnyName ':' AnyName [typeparams]
             '(' [parlist] ')' [':' rettype] block end
tlstaticfunc ::= [local] function AnyName '.' AnyName [typeparams]
                 '(' [parlist] ')' [':' rettype] block end
tlfunc ::= [local] function AnyName [typeparams]
           '(' [parlist] ')' [':' rettype] block end
tlforeignfunc ::= foreign function AnyName
                  '(' [foreignparlist] ')' [':' foreigntype] block end
tlvar ::= [local] [const] AnyName
          (':' type ['=' exp] | '=' exp)
tlrecord ::= [local] record AnyName [typeparams] {recordfield} end
tlunion ::= [local] union AnyName [typeparams] {unionvariant} end
tlinterface ::= interface AnyName [typeparams] {interfacemember} end
tltype ::= [local] type AnyName '=' titantype
tlforeigntype ::= foreign type AnyName '=' foreigntype
tlimport ::= local Name '=' import importname
tlforeignimport ::= foreign import importname
importname ::= LiteralString | '(' LiteralString ')'
moduleinit ::= do block end
recordfield ::= [local] [const] AnyName ':' type [';']
unionvariant ::= [local] AnyName '(' [type] ')' [';']
interfacemember ::= interfacemethod | interfacefield
interfacemethod ::= function AnyName [typeparams]
                    '(' [parlist] ')' [':' rettype] [';']
interfacefield ::= AnyName ':' type [';']
parlist ::= param {',' param} [',' varargparam] | varargparam
param ::= Name ':' type
varargparam ::= '...' ':' type
foreignparlist ::= foreignparam {',' foreignparam} [',' '...'] | '...'
foreignparam ::= Name ':' foreigntype
typeparams ::= '<|' typeparam {',' typeparam} '|>'
typeparam ::= AnyName [':' namedtype]
typeargs ::= '<|' type {',' type} '|>'
namedtype ::= AnyName [typeargs] | AnyName '.' AnyName [typeargs]
```

A missing named Titan function return annotation means zero results; a missing foreign
function return annotation means C `void`. Lambda results are inferred when
the lambda omits its return annotation. A module variable needs an
annotation or initializer. An omitted initializer supplies nil, which its type
must admit; const initialization authority in the final initializer is
unchanged. A keyword followed by `:` or `=` may name a module variable before
that word is interpreted as a declaration keyword or modifier.

Foreign aliases are always module-local and do not accept `local`. Their RHS
must contain only raw C types, with no `owned` component. They become real
C typedefs in the module's generated `.ffi.h`. Explicit source imports inherit
those typedefs through the ordinary transitive C header environment; ordinary
Titan imports do not. Source-defined C variadics remain unsupported: the
foreign list syntax retains `...` so semantic analysis can diagnose it.

Record fields use optional types (`field: T?`), not `field?: T`.
Union variants use `none()` or `some(T)` and still carry at most one payload.

## Types

```text
type ::= titantype | foreign foreigntype
titantype ::= basetitan ['?']
basetitan ::= nil | boolean | integer | float | string | value
            | namedtype
            | const ['?'] '{' type '}'
            | '{' type '}' | '{' type ':' type '}'
            | function '(' [typelist] ')' [':' rettype]
            | owned foreigntype | '(' type ')'
typelist ::= type {',' type} [',' flextail] | flextail
flextail ::= '...' ':' type
rettype ::= '(' [typelist] ')' | type
foreigntype ::= const '*' baseforeign | '*' baseforeign
              | const baseforeign '[' ']' | baseforeign ['[' ']']
baseforeign ::= unsigned long long | unsigned char | unsigned short
              | unsigned int | unsigned long | signed char
              | long long | long double | float | long | void | bool
              | char | short | int | double
              | function '(' [foreigntypelist] ')' ':' foreigntype
              | '(' foreigntype ')' | AnyName
foreigntypelist ::= foreigntype {',' foreigntype} [',' '...'] | '...'
```

Titan constructors may contain foreign components, such as `{foreign int}` or
`function(foreign *char): integer`. Foreign constructors never contain Titan
types. Foreign names have no `ffi.` or module qualification. Nested foreign
constructors are grouped: `foreign *(*int)` is a pointer to a pointer, and
`owned (*int)[]` owns an array of pointer elements.

A foreign function type already denotes a C function pointer. For example,
`foreign function(int): int` is a callback pointer and
`foreign *(function(int): int)` points to such a pointer. Foreign signatures
reject Titan values, owned storage, direct array/function values, and source
variadics. The `void` result is valid; a `void` parameter is not.

An ordinary alias may contain foreign components inside actual Titan
constructors, but its resolved outer type cannot be directly foreign. Thus
`type A = {foreign int}` and `type B = (foreign int)?` are permitted, while
`type C = ((foreign int))` requires a foreign alias instead. Parentheses do not
change the type category. `owned` is a Titan type constructor: its foreign operand must resolve to a
pointer or array, including through a foreign alias. `type Owner = owned *Item`
and `owned Item[]?` are ordinary Titan alias/Option forms. Owned types cannot
occur in foreign alias RHS types or foreign function signatures or local
declarations inside foreign function bodies.
An outer `const` on the resolved foreign operand is rejected: Titan cannot
allocate and initialize const owned storage in one construct.

A colon immediately after a function type's parameter list is its return
annotation. `{function(): T}` is an Array of functions returning T;
`{(function()): T}` is a Map keyed by zero-result functions. At a function's
return annotation, parentheses delimit the result list. A parenthesized single
result may have `?` to make that result optional; a multiple-result list cannot
be optional. Fixed results precede a single flexible tail.

There are no source-written sized C arrays. An eligible direct local initialized
by `foreign T.new_array(positive_constant)` infers fixed automatic C-array
storage; an explicit `owned T[]` target requests GC-owned storage.
`foreign T[]` at an initialized local sink is the existing borrowed pointer
view, with pointer bounds/lifetime rules. See
[C allocation](c-ffi-expressions.md#target-directed-c-allocation).

## Blocks and statements

```text
block ::= simpleblock [catch simpleblock]
simpleblock ::= {statement} [returnstat]
statement ::= ';' | do block end
            | while exp do block end
            | repeat block until exp
            | if exp then block {elseif exp then block} [else block] end
            | case exp {casearm} [else block] end
            | for decl '=' exp ',' exp [',' exp] do block end
            | for decl {',' decl} in explist do block end
            | [local] const decllist '=' explist
            | local decllist ['=' explist]
            | varlist '=' explist | break | raise [exp]
            | defer statement | callstmt
returnstat ::= return [explist] [';']
casearm ::= when AnyName '(' [Name] ')' then block
decl ::= Name ['?'] [':' type]
decllist ::= decl {',' decl}
varlist ::= prefixexp {',' prefixexp}
callstmt ::= prefixexp
explist ::= exp {',' exp}
```

Semantic analysis requires assignment targets to be lvalues and expression
statements to be calls. It also enforces legal `break`, `raise`, `defer`,
case-arm payloads, const assignments, and nil initialization. A const local
always needs an expression list. `return` is the final statement of its block.

## Expressions

```text
exp ::= e1
e1 ::= e2 {or e2}
e2 ::= e3 {and e3}
e3 ::= e4 {('==' | '~=' | '<' | '>' | '<=' | '>=') e4}
e4 ::= e5 {'|' e5}
e5 ::= e6 {'~' e6}
e6 ::= e7 {'&' e7}
e7 ::= e8 {('<<' | '>>') e8}
e8 ::= e9 {'..' e9}
e9 ::= e10 {('+' | '-') e10}
e10 ::= e11 {('*' | '/' | '//' | '%') e11}
e11 ::= e12 [(as | is) type]
e12 ::= {unop} e13
e13 ::= prefixexp {'^' {unop} prefixexp}
unop ::= not | '#' | '-' | '~'
prefixexp ::= baseexp {suffixexp}
baseexp ::= nil | false | true | Numeral | LiteralString
          | Name [typeargs] | constructor | lambda | '(' exp ')'
          | '...' [exp] | '#' '...'
          | foreign foreigntype '.' foreignop
foreignop ::= new '(' [exp] ')' | new_array '(' exp ')'
            | sizeof | alignof
suffixexp ::= '.' AnyName [typeargs] | ':' AnyName [typeargs]
            | '(' [explist] ')' | '{' [namedarglist] '}'
            | LiteralString | '[' exp ']' | '[' exp ',' exp ']'
            | '[' ',' exp ']' | '[' exp ',' ']'
lambda ::= function '(' [lambdaparlist] ')' [':' rettype] block end
lambdaparlist ::= lambdaparam {',' lambdaparam} [',' lambdavarargparam]
               | lambdavarargparam
lambdaparam ::= Name [':' type]
lambdavarargparam ::= '...' [':' type]
namedarglist ::= namedarg {fieldsep namedarg} [fieldsep]
namedarg ::= AnyName '=' exp
constructor ::= '{' [fieldlist] '}'
fieldlist ::= field {fieldsep field} [fieldsep]
field ::= AnyName '=' exp | '[' exp ']' '=' exp | exp
fieldsep ::= ',' | ';'
```

The foreign pseudo-expression selects an operation on its entire foreign type;
the first dot ends that type. `foreign T.new(count)` is valid specifically for
a struct with a flexible array member. Other `new` calls take no arguments.
The pseudo-operation cannot be detached as a callable value.

A colon selector denotes a bound method, optionally followed by a call. Generic
owner arguments attach before selection (`Box<|integer|>.new(...)`). Literal
string calls abbreviate one positional argument; brace calls are named calls.
Bracket commas distinguish indexing from ranges without reparsing the index.

After `...`, `[` selects vararg indexing/ranging; otherwise a token that can
start an expression commits to the complete collection-spread subject. If no
such token follows, the expression is bare varargs. `#...` is a dedicated count
atom when the dots are not followed by `[`: `#... - 1` subtracts from the
vararg count, while `#...[1]` applies length to the first vararg. Parentheses
adjust a call, bare varargs, or collection spread to one result. Semantic
analysis rejects bare varargs and spreads outside permitted tail positions;
the expression parser does not enforce expression-list position.

### Precedence and associativity

From lowest to highest:

| Operators | Associativity |
| --- | --- |
| `or` | left |
| `and` | left |
| `<` `>` `<=` `>=` `~=` `==` | left |
| `\|` | left |
| binary `~` | left |
| `&` | left |
| `<<` `>>` | left |
| `..` | right |
| `+` `-` | left |
| `*` `/` `//` `%` | left |
| `as` `is` | non-associative, after a unary expression |
| unary `not` `#` `-` `~` | prefix |
| `^` | right |

Thus `-2^2` is `-(2^2)`, `2^-3` is `2^(-3)`, and `a^b^c` is
`a^(b^c)`. Chaining casts/type tests requires explicit parentheses. Operator
chains and lists are accumulated with folds; genuinely nested syntax still
uses the parser's ordinary nesting limits. Width does not justify speculative
recursive lookahead or increasing LPeg's stack limit.

The implementation dispatches with a constant number of terminal tokens.
Ordered alternatives do not share a prefix containing a syntactic nonterminal;
once that terminal dispatch chooses a construct, its syntactic descents commit
with explicit error labels. Bounded token-only convenience rules are the
exception. Lexing a complete identifier or literal is separate from syntactic
lookahead.
