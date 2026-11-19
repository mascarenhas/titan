# Lexical, conversion, and grammar reference

This appendix specifies Titan's lexical conventions, operator precedence,
type-conversion boundary matrix, and complete EBNF syntax for Titan modules
and `foreign function` bodies. In the grammar productions, `{A}` denotes zero
or more repetitions of `A`, `[A]` denotes an optional `A`, `|` separates
alternatives, and keywords and quoted punctuation are terminals. Whitespace
and comments may appear between tokens. Each source file must match one
complete `program`; trailing tokens are a syntax error. For parser internals,
see [Lexer and parser](../implementation/lexer-parser.md).

## Lexical conventions

### Identifiers and reserved words

Identifiers match ASCII `[A-Za-z_][A-Za-z0-9_]*` using longest match
(`integer_count`, `return17`, and `_end` are single identifiers). Titan has
**38 reserved words**:

```text
and      as       break     case     catch    const    defer    do
else     elseif   end       false    finally  for      foreign  function
goto     if       import    in       interface is      local    nil
not      or       owned     raise    record   repeat   return   then
true     type     union     until    when     while
```

`goto` and `finally` are reserved words with no statement forms.

| Category | Spelling | Where accepted |
| --- | --- | --- |
| **Reserved words** | The 38 keywords above | Syntactic keywords and `AnyName` positions; rejected in `Name` positions. |
| **Contextual type words** | `boolean`, `integer`, `float`, `string`, `value` | Denote basic types in unqualified Titan type positions; behave as ordinary `Name` identifiers everywhere else (variables, parameters, fields). |
| **Contextual C primitives** | `void`, `bool`, `char`, `short`, `int`, `long`, `float`, `double`, `signed`, `unsigned` | Denote C types inside `foreign` types and `foreign function` bodies; ordinary identifiers elsewhere. |
| **`Name`** | Any ASCII identifier except the 38 reserved words | `import` bindings, parameters, local variables, lambda parameters, generic-`for` binders, `case` local bindings, bare expression names. |
| **`AnyName`** | Any ASCII identifier, including reserved words | Top-level declarations (variables, functions, methods, statics, types, records, unions, Interfaces), type parameters, record fields, union variant and part names, Interface members, `case` named part selectors (`alias = keyword`), `.`/`:` selectors, named-call keys, record constructor keys. |
| **Built-in readonly bindings** | `ffi`, `L`, `M`, `self` | Not keywords. `ffi` accesses C declarations (shadowable). Ordinary functions, methods, lambdas, and module initializers bind `L` (`foreign *lua_State`) and `M` (current module, supporting `M.member`, `M.Type`, and `M as foreign *Udata` when `titan/ffi.h` is imported). Methods bind `self`. `foreign function` bodies receive neither `L` nor `M`. |

### Tokens and punctuation

```text
+   -   *   /   //  %   ^   #   &   ~   |   <<  >>  ..
==  ~=  <   >   <=  >=  =   <|  |>
(   )   [   ]   {   }   ;   :   ,   .   ... ?
```

`<|` and `|>` delimit generic type parameters and type arguments, leaving `<`
and `>` unambiguous as comparison operators. Function types always begin with
`function`. There is no unary pointer-dereference operator; index pointers
with `pointer[0]`.

### Comments

A short comment begins with `--` outside a string and runs to the end of the
line. A long comment begins with `--` immediately followed by an opening long
bracket (`--[[ ... ]]`, `--[=[ ... ]=]`, and so on) and may span multiple
lines. Documentation comments start with `---` (see [Modules](modules.md)).

```text
-- a short comment
--[[ a long
     comment ]]
--[==[ a long comment containing ]] safely ]==]
---[[ a short comment: the third '-' prevents a long bracket
```

### Numerals

A **Numeral** follows Lua 5.5 syntax:

- Decimal integers (`0`, `17`) and hexadecimal integers (`0x1F`).
- Decimal floats with a fractional part or signed decimal exponent `e`/`E`
  (`0.0`, `.5`, `4.`, `1e10`, `1.0e-1`), and hexadecimal floats with binary
  exponent `p`/`P` (`0x1ap2`, `0x1.8p1`).

A fractional part or exponent makes the numeral a `float`; otherwise it is an
`integer`. Negative literals such as `-1` parse as unary `-` applied to `1`.
The lexer consumes the longest run of digits, letters, dots, and signed
exponents at the right edge of a numeral and rejects malformed runs such as
`1.2.3`, `1e`, or `1337require`.

### String literals

A **LiteralString** is either a short string (`'...'` or `"..."`) or a long
bracket string (`[[...]]`, `[=[...]=]`, ...). Unescaped line breaks inside a
short string are syntax errors. Short strings support these escapes:

| Escape | Produces |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | Bell, backspace, form feed, newline, carriage return, horizontal tab, vertical tab |
| `\\` `\'` `\"` | Literal backslash, single quote, or double quote |
| `\` followed by a line break | A single `\n` (for `\n`, `\r`, `\n\r`, or `\r\n`) |
| `\ddd` | Byte with decimal value `ddd` (1 to 3 digits, strictly less than 256) |
| `\xXX` | Byte with hexadecimal value `XX` (exactly 2 hex digits) |
| `\u{XXX}` | UTF-8 encoding of Unicode scalar value `XXX` (1 or more hex digits, at most `10FFFF`) |
| `\z` | Empty; skips all following whitespace, including line breaks |

Titan enforces the Unicode ceiling `U+10FFFF` for `\u{...}` (stricter than
Lua 5.5's `0x7FFFFFFF`). Long strings interpret no escape sequences and skip
one line break immediately following the opening bracket:

```text
local bytes = '\65\x41\u{10FFFF}'
local joined = "one \z
                line"
local raw = [[
no \escapes here]]
local nested = [==[ contains ]] safely ]==]
```

## Precedence and associativity

From lowest precedence to highest:

| Precedence | Operators | Associativity |
| ---: | --- | --- |
| 1 | `or` | left |
| 2 | `and` | left |
| 3 | `<` `>` `<=` `>=` `~=` `==` | left |
| 4 | `\|` | left |
| 5 | binary `~` | left |
| 6 | `&` | left |
| 7 | `<<` `>>` | left |
| 8 | `..` | right |
| 9 | `+` `-` | left |
| 10 | `*` `/` `//` `%` | left |
| 11 | `as` `is` | non-associative (follows unary expressions) |
| 12 | unary `not` `#` `-` `~` | prefix |
| 13 | `^` | right |

Thus `-2^2` means `-(2^2)`, `2^-3` means `2^(-3)`, `a^b^c` means `a^(b^c)`,
and `v ^ 2 as integer` means `(v ^ 2) as integer`. Chaining `as` or `is`
requires explicit parentheses.

## Type conversion and boundary matrix

Titan has no general subtyping. Instead, the compiler applies distinct,
non-lifting operations depending on context: exact identity, direct automatic
conversions, gradual views/projections, directional callable adjustment,
explicit `as`/`is` casts, and dynamic boundary conversions. Transparent
`type` aliases and C typedef chains normalize before any check.

### Implicit adjustment contexts

The compiler applies implicit adjustments in exactly eight contexts:

1. Annotated local declarations (`local x: T = e`).
2. Assignments (`x = e`).
3. `return` expressions.
4. Call arguments (positional and named).
5. Array and Map index expressions.
6. Constructor slots (Array elements, Map keys/values, record literal fields).
7. Annotated module-variable initializers.
8. Generic `for ... in` tuple and loop-variable slots.

Numeric `for` bounds (`for i: T = start, stop, step do`) are **not**
conversion contexts: they unwrap Options (`T?` -> `T`) but require exact
numeric types (`integer` or `float`). Conditions (`if`, `while`, `repeat`)
accept any type using Lua truthiness (only `nil` and `false` are falsy).

### Boundary policy by context

| Context or operation | Rule | Runtime behavior |
| --- | --- | --- |
| Ordinary typed Titan sink | Identity, one direct conversion, a same-kind Array/Map gradual view, or directional callable adjustment. Scalar conversions do not lift through `{T}`, `{K: V}`, or `function`. | Runs the direct conversion; Array/Map gradual views keep the same object; non-exact function adjustment may allocate a fresh wrapper. |
| Mutable `{S}` `as const { T }` | Explicit only; `S` and `T` must be equal or gradually consistent. | Creates a shallow read-only copy preserving holes and length (or freezes in place when unaliased). |
| `{T}` or `const { T }` -> `const? { T }` | Implicit read-only view (and Option forms `({T})?` / `(const {T})?` -> `(const? {T})?`). | Zero-copy view; downcast back with explicit `as {T}` / `as const { T }` (runtime tag check). |
| Non-exact function `A -> B` (implicit or `as`) | Directional shape adjustment (aligned params/results/tails; no scalar, Option, C, or Interface coercions inside). | Evaluates operand once; creates a fresh wrapper when adapting a matching Titan closure, leaving other callables for runtime checked dispatch. |
| Implicit `value -> T` in a typed Titan sink | **Strict** projection (`T` must be guardable). | Requires `T`'s exact tag or nominal identity (plus compiler-witnessed Interfaces). Rejects `2.0` for `integer`, rejects non-booleans for `boolean`, and rejects raw C pointers. |
| Typed Array or Map element read | **Strict** guard on the requested element/value type. | Succeeds with the requested type or raises before native Titan uses the value. |
| Written `v as T` / `v is T` on `v: value` | **Dynamic conversion** (shared with genuine Lua boundaries). | `as` converts or raises; `is` returns `boolean` without raising and never narrows `v`'s static type. Both evaluate `v` once. |
| Genuine Lua argument, exported variable write, public record-field write, non-nil Array write, or Lua-callable return | Same **dynamic conversion** as `value as T`. | Applies the target-directed rules in the dynamic conversion table below. Writing `nil` to a mutable Array deletes the slot. |
| Concrete `R` -> Interface `I` | Statically checked structural satisfaction (methods and `const` fields; unions satisfy method-only Interfaces). | Allocates a fresh nominal `I` wrapper with field snapshots; advertises the `(R, I)` witness for dynamic `value`/Lua recovery. |
| `value as/is` raw C pointer | Explicitly unsafe written assertion only (disallowed in implicit projections and container reads). | Checks lightuserdata or `nil`; cannot verify pointee type or lifetime. |

### Direct automatic conversions

| From | To | Can fail at run time? |
| --- | --- | --- |
| `integer` | `float` | No. |
| `float` | `integer` | Yes: requires an exact in-range integer value (`2.0` succeeds, `2.5` raises). |
| Non-C Titan type (except `boolean`, `value`) | `boolean` | No: Lua truthiness (`nil` and `false` -> `false`, all else -> `true`). |
| `T` or `nil` | `T?` | No. |
| `T?` | `T` | Yes: raises if `nil`. |
| `S?` or `S` (with `S -> T`) | `T?` or `T` (non-Interface) | Preserves `nil` for `T?` targets; unwraps and converts for `T` targets (raises if `nil` or narrowing fails). |
| Satisfying `R` (or `R?`) | Interface `I` (or `I?`) | Only when unwrapping `R? -> I`; constructs a fresh `I` wrapper when present. |
| `integer` or `float` | `string` | No; **only** as an operand of `..` (`3 as string` is a compile error). |
| C integer or C float | `integer` or `float` (and vice versa) | Yes when narrowing outside the target range or non-finite float. |
| `nil` / C array / non-function pointer | Compatible C pointer / `void *` | No (`nil` -> `NULL`). |
| C pointer / `owned` C userdata | `boolean` | No (`NULL` -> `false`, non-null / owned -> `true`). |
| `string` | C `char *` / `void *` | No (FFI call boundary only; borrowed pointer). |
| Boxable C value | `value` | Yes for C numbers outside `lua_Integer`/`lua_Number`; no for pointers (lightuserdata), `owned` (full userdata), `Udata *`, or `TValue`. |

### Dynamic conversion rules (`value as/is T` and Lua boundaries)

| Target `T` | Accepted values and behavior |
| --- | --- |
| `integer` | Lua integer, or an exact in-range integral float (converted to integer). |
| `float` | Lua float or integer (converted to float). |
| `boolean` | Any value via Lua truthiness (`value is boolean` is always `true`). |
| `string`, record, union, `owned` C type | Exact runtime category or nominal metatable only. |
| Interface `I` | Existing exact `I` wrapper, or bare full userdata with a compiler-witnessed `(R, I)` conversion (never performs runtime method search). |
| `{T}`, `const { T }`, `const? { T }` | Canonical Titan Array proxy matching the qualifier (`const?` accepts either). Elements are not walked; later reads stay strict. |
| `{K: V}` | Any Lua table. Entries are not walked; later reads stay strict. |
| `function (...)` | Preserves the boxed value without wrapping; callability and argument/result checks run when called. |
| `T?` | Accepts `nil`, otherwise applies the dynamic rule for `T`. |
| `value` | Any Lua value unchanged. |

## Complete EBNF grammar

### Modules and declarations

Each source file contains top-level declarations and at most one final
`do ... end` initializer. In a folder module, each contributor parses
independently and only the main file may include the final initializer (see
[Modules](modules.md)).

```text
program        ::= {tldecl} [moduleinit]
tldecl         ::= tlmethod | tlstaticfunc | tlfunc | tlforeignfunc | tlvar
                 | tlrecord | tlunion | tlinterface | tltype | tlforeigntype
                 | tlimport | tlforeignimport | ';'
tlmethod       ::= [local] function AnyName ':' AnyName [typeparams]
                   '(' [parlist] ')' [':' rettype] block end
tlstaticfunc   ::= [local] function AnyName '.' AnyName [typeparams]
                   '(' [parlist] ')' [':' rettype] block end
tlfunc         ::= [local] function AnyName [typeparams]
                   '(' [parlist] ')' [':' rettype] block end
tlforeignfunc  ::= [local] foreign function AnyName
                   '(' [foreignparlist] ')' [':' foreigntype] fblock end
tlvar          ::= [local] [const] AnyName
                   (':' type ['=' exp] | '=' exp)
tlrecord       ::= [local] record AnyName [typeparams] {recordfield} end
tlunion        ::= [local] union AnyName [typeparams] {unionvariant} end
tlinterface    ::= interface AnyName [typeparams] {interfacemember} end
tltype         ::= [local] type AnyName '=' titantype
tlforeigntype  ::= foreign type AnyName '=' foreigntype
tlimport       ::= local Name '=' import importname
tlforeignimport ::= foreign import importname
importname     ::= LiteralString | '(' LiteralString ')'
moduleinit     ::= do block end
recordfield    ::= [local] [const] AnyName ':' type [';']
unionvariant   ::= [local] AnyName '(' [variantparts] ')' [';']
variantparts   ::= variantpart {',' variantpart} | type
variantpart    ::= AnyName ':' type
interfacemember ::= interfacemethod | interfacefield
interfacemethod ::= function AnyName [typeparams]
                    '(' [parlist] ')' [':' rettype] [';']
interfacefield ::= AnyName ':' type [';']
parlist        ::= param {',' param} [',' varargparam] | varargparam
param          ::= Name ':' type
varargparam    ::= '...' ':' type
foreignparlist ::= foreignparam {',' foreignparam} [',' '...'] | '...'
foreignparam   ::= Name ':' foreigntype
typeparams     ::= '<|' typeparam {',' typeparam} '|>'
typeparam      ::= AnyName [':' namedtype]
typeargs       ::= '<|' type {',' type} '|>'
namedtype      ::= AnyName [typeargs] | AnyName '.' AnyName [typeargs]
```

Syntactic notes:

- Omitting a return annotation on a named Titan function means zero results
  (`: ()`); omitting it on a `foreign function` means C `void`.
- A module variable needs either a type annotation or an initializer. Omitting
  the initializer supplies `nil`, so the annotated type must admit `nil`; an
  initializer-less `const` module variable may then be assigned inside
  `moduleinit`. A keyword followed by `:` or `=` names a module variable before
  being read as a declaration keyword.
- `foreign type` declarations are always module-local and do not accept
  `local`; their right-hand side must be a raw `foreigntype` with no `owned`.
- Source-defined C variadic `foreign function` declarations are rejected by
  semantic checking (`...` is parsed only to produce a clear diagnostic).
- Record fields use optional types (`field: T?`), not `field?: T`.
- Union variants accept zero parts (`none()`), one unnamed type (`some(T)`,
  shorthand for `some(value: T)`), or one or more named parts
  (`point(x: float, y: float)`). Flexible tails `...: T` are disallowed.
- `interface` declarations are top-level and always public.

### Types

```text
type            ::= titantype | foreign foreigntype
titantype       ::= basetitan ['?']
basetitan       ::= nil | boolean | integer | float | string | value
                  | namedtype
                  | const ['?'] '{' type '}'
                  | '{' type '}' | '{' type ':' type '}'
                  | function '(' [typelist] ')' [':' rettype]
                  | owned foreigntype | '(' type ')'
typelist        ::= type {',' type} [',' flextail] | flextail
flextail        ::= '...' ':' type
rettype         ::= '(' [typelist] ')' | type
foreigntype     ::= const '*' baseforeign | '*' baseforeign
                  | const baseforeign '[' ']' | baseforeign ['[' ']']
baseforeign     ::= unsigned long long | unsigned char | unsigned short
                  | unsigned int | unsigned long | signed char
                  | long long | long double | float | long | void | bool
                  | char | short | int | double
                  | function '(' [foreigntypelist] ')' ':' foreigntype
                  | '(' foreigntype ')' | AnyName
foreigntypelist ::= foreigntype {',' foreigntype} [',' '...'] | '...'
```

Syntactic notes:

- Titan type constructors may contain `foreign` components (`{foreign int}`,
  `function(foreign *char): integer`); `foreigntype` never contains Titan
  types or `ffi.`/module qualifiers. Group nested C constructors with
  parentheses (`foreign *(*int)`, `owned (*int)[]`).
- `foreign function(int): int` already denotes a C function pointer. `void` is
  valid as a return type, not as a parameter type.
- `owned` is a Titan constructor whose operand must resolve to a C pointer or
  array without an outer `const`. Ordinary `type` aliases may wrap foreign
  components inside Titan constructors (`type A = {foreign int}`) but cannot
  alias a bare raw C type (`type C = ((foreign int))` requires `foreign type`).
- A colon immediately following a function type's parameter list starts its
  return type: `{function(): T}` is an Array of functions, whereas
  `{(function()): T}` is a Map keyed by zero-result functions.
- Source-written sized C array types do not exist; fixed automatic C arrays
  are inferred from `foreign T.new_array(constant)` at a direct local (see
  [Calling C: the FFI](ffi.md)).

### Blocks and statements

```text
block       ::= simpleblock [catch simpleblock]
simpleblock ::= {statement} [returnstat]
statement   ::= ';' | do block end
              | while exp do block end
              | repeat block until exp
              | if exp then block {elseif exp then block} [else block] end
              | case exp {casearm} [else block] end
              | for decl '=' exp ',' exp [',' exp] do block end
              | for decl {',' decl} in explist do block end
              | [local] const decllist '=' explist
              | local decllist ['=' explist]
              | varlist '=' explist | break | raise [exp [',' exp]]
              | defer statement | callstmt
returnstat  ::= return [explist] [';']
casearm     ::= when AnyName '(' [Name {',' Name}] ')' then block
              | when AnyName '{' {namedbinder [fieldsep]} '}' then block
namedbinder ::= Name ['=' AnyName]
decl        ::= Name ['?'] [':' type]
decllist    ::= decl {',' decl}
varlist     ::= prefixexp {',' prefixexp}
callstmt    ::= prefixexp
explist     ::= exp {',' exp}
```

Syntactic notes:

- `return` must be the last statement in its block.
- Assignment targets must be lvalues, expression statements must be calls, and
  `const` locals always require an initializer list.
- In `case`, positional binders match a prefix of the variant's parts; named
  binders (`local_alias = part_name`, or bare `part_name`) match parts in any
  order and may omit parts. Keyword part names require a `Name` alias on the
  left. Repeating a part in one named pattern is a syntax error.

### Expressions

```text
exp           ::= e1
e1            ::= e2 {or e2}
e2            ::= e3 {and e3}
e3            ::= e4 {('==' | '~=' | '<' | '>' | '<=' | '>=') e4}
e4            ::= e5 {'|' e5}
e5            ::= e6 {'~' e6}
e6            ::= e7 {'&' e7}
e7            ::= e8 {('<<' | '>>') e8}
e8            ::= e9 {'..' e9}
e9            ::= e10 {('+' | '-') e10}
e10           ::= e11 {('*' | '/' | '//' | '%') e11}
e11           ::= e12 [(as | is) type ['(' exp ')']]
e12           ::= {unop} e13
e13           ::= prefixexp {'^' {unop} prefixexp}
unop          ::= not | '#' | '-' | '~'
prefixexp     ::= baseexp {suffixexp}
baseexp       ::= nil | false | true | Numeral | LiteralString
                | Name [typeargs] | constructor | lambda | '(' exp ')'
                | '...' [exp] | '#' '...'
                | foreign foreigntype '.' foreignop
foreignop     ::= new '(' [exp] ')' | new_array '(' exp ')'
                | sizeof | alignof
suffixexp     ::= '.' AnyName [typeargs] | ':' AnyName [typeargs]
                | '(' [explist] ')' | '{' [namedarglist] '}'
                | LiteralString | '[' exp ']' | '[' exp ',' exp ']'
                | '[' ',' exp ']' | '[' exp ',' ']'
lambda        ::= function '(' [lambdaparlist] ')' [':' rettype] block end
lambdaparlist ::= lambdaparam {',' lambdaparam} [',' lambdavarargparam]
                | lambdavarargparam
lambdaparam   ::= Name [':' type]
lambdavarargparam ::= '...' [':' type]
namedarglist  ::= namedarg {fieldsep namedarg} [fieldsep]
namedarg      ::= AnyName '=' exp
constructor   ::= '{' [fieldlist] '}'
fieldlist     ::= field {fieldsep field} [fieldsep]
field         ::= AnyName '=' exp | '[' exp ']' '=' exp | exp
fieldsep      ::= ',' | ';'
```

Syntactic notes:

- **Counted pointer-to-string casts:** The optional `(exp)` after `as`/`is`
  supplies the byte count for a character or `void` pointer cast to `string`
  (see [Calling C: the FFI](ffi.md)). Because suffix syntax is not
  newline-sensitive, write a semicolon after an uncounted cast when a
  parenthesized call statement follows on the next line:

  ```text
  local bytes = pointer as string
  (length)                         -- continues the counted cast

  local text = pointer as string;
  (consume)(text)                  -- separate call statement
  ```

- **Foreign pseudo-expressions:** The first `.` ends `foreigntype`.
  `foreign T.new(count)` is valid only for structs with a flexible array
  member; other `new` calls take no arguments.
- **Spreads and varargs:** After `...`, `[` selects vararg indexing (`...[i]`)
  or vararg slicing (`...[i, j]`); otherwise an expression token starts a
  collection spread (`...xs`, `...xs[i, j]`), and no expression token yields
  bare `...`. `#...` is an atomic vararg-count expression (`#... - 1`
  subtracts from the count, whereas `#...[1]` takes the length of the first
  vararg). Parentheses adjust a call, bare `...`, or spread (including ranged
  slices such as `(...[1, 2])`) to a single value.
- **Calls and selectors:** `obj:method` without arguments yields a bound
  method value; `{ ... }` calls are always named calls; string-literal calls
  pass one positional string argument.

### Foreign function bodies

A `foreign function` body uses a restricted raw-C grammar (`fblock`) in which
C types are written without the `foreign` prefix (see
[Foreign functions and C callbacks](foreign-functions.md)):

```text
fblock        ::= {fstatement} [freturn]
fstatement    ::= ';' | do fblock end
                | while fexp do fblock end
                | repeat fblock until fexp
                | if fexp then fblock {elseif fexp then fblock} [else fblock] end
                | for fdecl '=' fexp ',' fexp [',' fexp] do fblock end
                | [local] const fdecllist '=' fexplist
                | local fdecllist ['=' fexplist]
                | fvarlist '=' fexplist | break | fcallstmt
freturn       ::= return [fexp] [';']
fdecl         ::= Name [':' foreigntype]
fdecllist     ::= fdecl {',' fdecl}
fvarlist      ::= fprefixexp {',' fprefixexp}
fcallstmt     ::= fprefixexp
fexplist      ::= fexp {',' fexp}
fexp          ::= fe3
fe3           ::= fe4 {('==' | '~=' | '<' | '>' | '<=' | '>=') fe4}
fe4           ::= fe5 {'|' fe5}
fe5           ::= fe6 {'~' fe6}
fe6           ::= fe7 {'&' fe7}
fe7           ::= fe9 {('<<' | '>>') fe9}
fe9           ::= fe10 {('+' | '-') fe10}
fe10          ::= fe11 {('*' | '/' | '//' | '%') fe11}
fe11          ::= fe12 [as foreigntype]
fe12          ::= {funop} fe13
fe13          ::= fprefixexp {'^' {funop} fprefixexp}
funop         ::= '#' | '-' | '~'
fprefixexp    ::= fbaseexp {fsuffixexp}
fbaseexp      ::= nil | false | true | Numeral | LiteralString
                | Name | '(' fexp ')'
                | foreign foreigntype '.' foreignop
fsuffixexp    ::= '.' AnyName | '[' fexp ']'
                | '(' [fexplist] ')' | '{' [fnamedarglist] '}'
                | LiteralString
fnamedarglist ::= fnamedarg {fieldsep fnamedarg} [fieldsep]
fnamedarg     ::= AnyName '=' fexp
```

The precedence levels match the ordinary expression grammar, omitting `or`,
`and`, and `..` (`fe1`, `fe2`, `fe8`). All statements, operators, and literals
have C semantics.

Disallowed inside a `foreign function` body:

- **Statements:** `defer`, `catch`, `raise`, `case`, generic `for ... in`.
- **Expressions:** lambdas, `{ ... }` constructors, `:` method selection,
  generic `<|...|>` arguments, `...` and spreads, range slices, `is`, counted
  `as T(n)` casts, `..`, `and`, `or`, and `not`.
- **Types and declarations:** `?` options, multiple returns, `owned`, Titan
  Array/Map types, and a leading `foreign` before type annotations (only
  `foreign T.new()`, `.new_array(...)`, `.sizeof`, and `.alignof` keep the
  `foreign` keyword). Semantic checking also rejects `#` and any allocation
  other than zeroed local storage.
- **Semicolon after cast:** As in ordinary Titan, write `;` after `x as T` if
  a parenthesized call statement follows immediately.
