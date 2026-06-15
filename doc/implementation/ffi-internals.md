# FFI internals

`foreign import "stdio.h"` puts a full C toolchain inside the compiler: a
hand-written C preprocessor, a C99 parser and a declaration extractor, all in
pure Lua under `c-parser/`, plus a C-type-to-Titan-type converter
(`titan-compiler/foreigntypes.lua`) and dedicated paths in the
[code generator](codegen-overview.md). The headline facts: the header is
parsed at *compile time* by Titan's own parser, not by the system compiler;
the result is a `Type.ForeignModule` whose members the [checker](checker.md)
treats like module members; and a foreign call compiles to a plain C call of
the bare C name — the generated translation unit `#include`s the header
again, so the C compiler sees the real prototypes. For the user-facing
behavior see [the language FFI chapter](../language/ffi.md).

## Pipeline orchestration

The entry point is the checker's `Ast.TopLevelForeignImport` handler
(`checker.lua`), which calls `cdriver.process_file(node.headername)`
(`c-parser/cdriver.lua`). That runs four stages:

1. `cpp.parse_file(filename)` — preprocess; returns a context `ctx` carrying
   the output lines and the final `#define` set.
2. `c99.match_language_grammar(table.concat(ctx.output, "\n") .. " $EOF$")` —
   parse. The literal sentinel `$EOF$` is appended because the grammar's
   start rule ends with it (`translationUnit <- %s* {| externalDeclaration* |}
   "$EOF$"`), detecting trailing garbage without a `!.` pattern.
3. `ctypes.register_types(res)` — fold the parse tree into a **TypeList**.
4. `cdefines.register_defines(ffi_types, ctx.defines)` — add typed entries
   for object-like `#define`s to the same TypeList.

On success `process_file` returns only the TypeList. The checker iterates it
**in declaration order**, converting each entry with
`foreigntypes.convert(st, ftype)`; each success becomes a
`types.ModuleMember(headername, fname, decl)` and is *also* registered in the
symbol table's `foreign_types` namespace (`symtab.lua`, `add_foreign_type`)
so later types can resolve typedef names. The handler then builds
`types.ForeignModule(headername, members)`, stores it as `node._type`, and
binds the local name with `st:add_symbol`.

Two details matter to contributors. First, `symtab.foreign_types` is **per
module**, not per import: a typedef registered while importing `stdio.h`
(say, `FILE`) is visible while converting later headers in the same module,
which is how `string.h`'s `strcpy` and `stdio.h`'s `fopen` agree about types.
Second, the failure paths are asymmetric: if preprocessing or parsing fails,
`node._type = types.Nil()` and the error string is reported through
`checker.typeerror` at the import's location — the shape is
`foo.titan:1:1: type error: failed preprocessing 'does_not_exist.h':
does_not_exist.h: No such file or directory` (the spec checks the
`failed preprocessing '...'` part). The per-member failure path is different:
when `foreigntypes.convert` returns a conversion failure — its
`"FIXME unconverted ..."` fallback (for example a header declaring
`extern restrict x;`, whose type reduces to an empty token array) or an
unsupported C type — that member is **skipped** and the rest of the header
still imports. Referencing a skipped member is then a clean
`member '...' not found` error, never a checker or codegen crash on an
unhandled type.

## The preprocessor (`c-parser/cpp.lua`)

### Discovering the host environment

The preprocessor asks the real C environment about itself, once per process:

* **Predefined macros**: `io.popen("LANG=C gcc -dM -E - < /dev/null")`, whose
  output is fed back through `cpp.parse_file` with a blank context to build a
  define table, cached process-wide. Hard-coded fixups then neutralize GCC
  builtins the pipeline cannot digest: `__builtin_va_list` → `char *`,
  `__extension__` → nothing, `__attribute__` → a function-like macro that
  swallows its argument, `__restrict__`/`__restrict` → `restrict`,
  `__inline__`/`__inline` → `inline`.
* **Include search paths**: `io.popen("LANG=C cpp -v /dev/null -o /dev/null
  2>&1")`, scraping the lines between `#include "..." search starts here` /
  `#include <...> search starts here` and `End of search list`; if the popen
  fails, the fallback is `{ quote = {}, system = { "/usr/include" } }`.

Hence the FFI's compile-time POSIX dependency: `gcc` and `cpp` on `PATH`,
`/dev/null`, `LANG=C`.

### Phase one: lines, continuations, comments

`cpp.initial_processing` reads line by line, merging backslash-continued
lines and replacing comments with a single space, driven by a character state
machine (the `states` table) with states `any`, `dquote`/`squote` (string and
char literals, with backslash sub-states), `slash`, `line_comment`,
`block_comment` and `try_end_block_comment`. It is literal-aware (`"/* not a
comment */"` survives) and block comments span lines via `continue_line`.
Explicitly unsupported: character-set conversion and trigraphs.

### Directives and conditionals

Each processed line is tokenized by `c99.match_preprocessing_grammar`, and
`cpp.parse_file` interprets directives: `define` (object- and function-like,
including `...` varargs), `undef`, `ifdef`, `ifndef`, `if`, `elif`, `else`,
`endif`, `include`, `include_next`. `#error` and `#pragma` are **silently
ignored** — an `#error` in a header does not fail the import, though the
build can still die later, at the C-compiler stage, when the generated C
re-`#include`s the header and the real compiler hits the same `#error`.
Conditional nesting is a stack `ifmode` of `true`/`false`/`"skip"`; an
unmatched `elif`/`else`/`endif` returns `nil, "unexpected directive ..."`.
`#line` is recognized by the tokenizer but has no handler in the directive
chain: it falls through to the plain-line branch and contributes an empty
output line.

`#if`/`#elif` expressions are evaluated by `eval_exp` over a parse from the
preprocessing-expression grammar. It supports
`+ - * / >> << == != >= <= > < ! && || ?:` and `defined`; decimal, octal and
hex literals have `U`/`L` suffixes stripped via `val:gsub("U*L*$", "")`;
identifiers expand recursively through the define set, and anything unknown
or unparseable evaluates to `0` (marked `-- FIXME`). The shifts are marked
`-- FIXME C semantics` (Lua numbers, not C widths), and an operator outside
the list raises `error("unimplemented operator ...")` — a raw Lua error that
aborts the compiler rather than a diagnostic.

### Macro expansion

`macro_expand` rewrites a token list in place. Function-like macro arguments
are gathered by `consume_parentheses`, which may pull tokens from *following
lines* (an unterminated invocation raises `error("unterminated function-like
macro")`); `replace_args` implements `#` (stringification) and `##` (pasting
by concatenating neighboring tokens). Recursion is suppressed positionally: a
`noloop` map records, per macro name, the token index at or before which that
name must not expand again — the standard no-self-re-expansion rule,
approximated by position. `cpp.expand_macro(name, define_set)` is a small public wrapper
that fully expands one macro to a string; it exists for `cdefines.lua`.

### Include resolution

`find_file` implements the two C search modes: `"quote"` tries the including
file's directory then the scraped quote directories; `"system"` tries the
scraped system directories; `include_next` re-runs the search dropping every
directory up to and including the one that produced the current file. Two
asymmetries: a failed quote include is **retried as a system include** (the
source comments this is needed for Mac system headers), and the header named
in `foreign import` itself (a non-absolute top-level filename) is searched in
the *system* path first — that is how `"stdio.h"` resolves to
`/usr/include/stdio.h`. An `#include` miss surfaces as `<name>:file not
found` inside the `failed preprocessing ...` compile-time error; a missing
top-level header surfaces `io.open`'s message (`... No such file or
directory`) instead.

## The C99 grammars (`c-parser/c99.lua`)

`c99.lua` holds one set of LPegLabel/relabel rule fragments — adapted from
Wesley Smith's MIT-licensed LPeg C99 grammar — compiled into **four**
grammars:

| Grammar | Built from | Used for |
| --- | --- | --- |
| `preprocessing_grammar` | preprocessing + lexical rules | tokenizing lines in `cpp.lua` |
| `preprocessing_expression_grammar` | preprocessing expression + lexical + common expression rules | `#if` expressions |
| `language_expression_grammar` | *simplified* expression rules (no typedefs, no casts) + lexical + common | `cdefines.lua` macro bodies |
| `language_grammar` | full C99 declarations and statements + expression + lexical rules | the preprocessed header |

**Typedef ambiguity.** C is not context-free: `T * x;` parses differently
depending on whether `T` names a type. The classic lexer-feedback hack
appears as a module-global `local typedefs = {}`: the semantic action
`decl_ids` records every name declared with storage class `typedef`, and the
rule `typedefName <- IDENTIFIER => is_typedef` consults the table as a
match-time predicate. `c99.match_language_grammar` resets the table on entry,
so the language grammar is **non-reentrant but self-resetting** — fine for
sequential imports, hostile to anything concurrent.

**Tolerated extensions.** Real system headers are not C99, so the grammar
accepts (and mostly discards) `__attribute__((...))`,
`__asm__(...)`/`__asm(...)` (`__asm__` also as a statement),
`__DARWIN_ALIAS_STARTING_MAC_1060(...)`, `__AVAILABILITY_INTERNAL...`, the
type specifiers `_Bool`, `_Complex`, `__int128_t`, `__uint128_t`, `__int128`,
anonymous unions inside structs, and Apple blocks in the pointer rule
(`pointer <- {| ({ "*"/"^" } _ typeQualifier*)+ |}`); the preprocessing
grammar additionally knows GCC's `include_next` and `warning` directives and
C's digraphs.

**Failure reporting.** The shared `match` helper turns a failed parse into
`res, err, line, col, fragment` — `fragment` being the 21 characters at the
failure position — which `cdriver` formats as the
`failed parsing: <file>:<line>:<col>: <label>` compile-time error. For
grammar debugging, a `c99.tracing` flag wired to a `TRACE` rule prints
positions as the parser advances.

## TypeList construction (`c-parser/ctypes.lua`)

`ctypes.register_types` reduces the parse tree to a **TypeList**, which is
deliberately two structures in one table: a name→CType map *and* an ordered
array of `{ name = ..., type = ... }` records — `add_type` writes both. The
checker iterates the array part (members convert in declaration order,
typedefs before their users); `refer` and `cdefines` use the map part.

Per top-level declaration, `register_types` dispatches:

* `extern` (or plain) declarations → `register_decls`: variables and function
  prototypes. Function CTypes look like
  `{ type = "function", name, ret = { type = ... }, params, vararg }`;
  `get_params` drops a lone `void` parameter and sets `vararg = true` on a
  `"..."` token.
* `extern inline` function *definitions* → reshaped into plain declarations
  (`register_function`): body dropped, prototype kept.
* `static` functions → `register_static_function`, which does nothing —
  static functions are deliberately invisible to Titan.
* `typedef` → a CType `{ type = "typedef", name, def }`.
* struct/union/enum specifiers → composite registration (below). A specifier
  with no declarators is a forward declaration and is skipped — and because
  that declarator test is the catch-all, anything else without declarators
  is silently dropped too: a plain non-`extern` function *definition* never
  becomes a member, and the `"FIXME Uncategorized declaration"` fallback
  below these branches is unreachable.

**Composite keying.** Structs, unions and enums are stored under
`spectype .. "@" .. name` — `struct@FILE`, `enum@__socket_type` — so tag names
cannot collide with ordinary identifiers; *anonymous* composites key by
`tostring(parts)`, the Lua identity of their member-list table. A bare
reference (`struct foo` with no fields) reuses the registered entry or
records a named placeholder; forward declarations register a fieldless
placeholder CType filled in later. Enum *constants* are added to the
TypeList as names mapping to the enum's CType — but only when `get_enum`
actually runs, which it does for enums reached through a *typedef* (via
`get_type`'s composite branch); a bare top-level `enum color { ... };`
declaration falls through `register_types`' dispatch as a forward
declaration and registers nothing, so its constants are missing members
at the Titan level (`member '...' not found`). Even when registered,
their **values are not stored** (`-- TODO store enum actual values`), so
typedef'd-enum constants surface as integer members; the other working
path for constants is `#define`s, below. Because headers redeclare things
constantly, every re-registration is structurally compared with
`equal_declarations` (struct names, function return/params/`vararg`);
mismatches fail the import with `"redeclaration for <key>"` or
`"inconsistent declaration for <name> - <old> VERSUS <new>"`.

**Types as token arrays.** A non-composite type is reduced by `get_type` to a
flat token array such as `{"unsigned", "long", "*"}`: storage-class and
qualifier words (`extern`, `static`, `typedef`, `restrict`, `inline`,
`register`) are skipped, base-type words pass through, array-declarator
extents are constant-folded by `calculate` (which only knows `+ - * /`), and
unknown tokens produce `nil, "FIXME unknown type ..."`. Anonymous unions
inside structs are flattened into the parent's field list, and a known hole
is flagged in the source: declarator lists of mixed pointerness
(`int *x, y, *z;` — `-- FIXME multiple ids`) are not handled correctly.

## `#define` typing (`c-parser/cdefines.lua`)

`cdefines.register_defines` walks the final define set and tries to give a
*type* to each object-like macro. Macros whose stored definition has an empty
array part are skipped — that covers both empty replacements and
function-like macros (whose definition tables are hash-only), which is why
function-like macros never become members. Each candidate is fully expanded
with `cpp.expand_macro` and parsed with the **simplified** expression grammar
(`c99.match_language_expression_grammar`); a parse failure is silently
ignored — the macro just does not become a member.

`get_type_of_exp` then infers a C type, best-effort: single tokens by shape
(leading `"`/`L"` → `{"const","char","*"}`, `'`/`L'` → `{"const","char"}`,
trailing `LL` → `long long`, trailing `L` → `long`, contains `.` → `double`,
else — including any bare identifier — `int`); `?:` → its second operand's
type; the comma operator → the last operand; arithmetic binops → the
promotion ladder `double > long long > long > int`; relational operators →
`int`; bit operators → the left operand (`-- ...or should it be int?`). An
unsupported operator prints `FIXME unsupported op <op>` **to stdout** during
compilation (importing glibc's `stdio.h` prints one for `&&`) and yields no
member. Two groups of branches are dead code: the `exp.unop` tests (the
grammar only ever sets `op`) and the function-call branch keyed on
`exp[2].args`, which would map a call to the called function's return type —
the grammar attaches call arguments as a `postfix` field on the callee token
instead, so a call-shaped macro lands in the single-token branch above and
comes out `int` (a macro defined as a call of a `double`-returning function
checks as `integer`).

A successful inference adds `{ type = <token array> }` under the macro's
name — from this point on, a `#define` is indistinguishable from a global
variable. That is the entire mechanism behind `errno.ENOENT` working as an
`integer` member (`spec/coder_spec.lua`, "can use foreign defines").

## From C types to Titan types (`titan-compiler/foreigntypes.lua`)

`foreigntypes.convert(st, ftype)` dispatches on the CType:

| CType | Converted result |
| --- | --- |
| `function` | `types.Function(ptypes, rettypes, ftype.vararg)`, params and the single return converted recursively (a wrapping decl with `islocal`/`isforeign` flags is built but discarded — only the bare type is returned) |
| `typedef` | ad-hoc `{ _tag = "Type.Typedef", name, _type = <resolved> }` |
| `enum` | a real integer type (constants behave as integers) |
| `struct` / `union` | stub `{ _tag = "Struct"/"Union", name, data = ftype }` — fields are **not** converted (`-- TODO process fields`) |
| token-array type | `type_from_name` (below) |
| anything else | `nil, "FIXME unconverted ..."` |

`type_from_name` first strips `const` and `restrict`, then applies, in order:
a single token naming a registered foreign typedef → that typedef's converted
decl; `void` → `types.Nil()`; `int` or `long` → Integer; `double` → Float;
exactly `{"char","*"}` → String; any other trailing `*` → ad-hoc
`{ _tag = "Type.Pointer", type = <recursive> }` (so `void*` is
`Pointer(Nil)`, `FILE*` is `Pointer(Typedef FILE)`); anything else →
a conversion failure (`nil, "unsupported C type: ..."`), which the importer
skips so the member is simply omitted. Note what is unsupported and therefore
skipped: a lone `char`, `float`, `short`, and every spelled-out `unsigned`
variant.

Typedef resolution (`convert_typedef`) scans the definition tokens: nested
tables convert recursively, known foreign-type names resolve through the
symbol table, bare `long`s are *counted* (only `long`s ⇒ Integer), `double` ⇒
Float (`error("NYI long double")` if `long`s were seen — another raw Lua
error), and — only here, unlike in `type_from_name` — `int`, `char` and
`short` all map to Integer. A typedef that resolves to nothing simply has no
`_type`, and uses of it fail downstream.

Two cross-cutting caveats. First, **none of these tags are
typedecl-registered**: `Type.Pointer`, `Type.Typedef`, `Struct` and `Union`
are plain table literals with no constructors in
`types.lua` and no arity checking (see [AST and typedecl](ast-typedecl.md));
code that switches exhaustively on official `Type.*` tags will not see them
coming. Second, `types.tostring` knows just enough to render errors:
`Pointer(Nil)` prints as `void pointer`, other pointers as `pointer to <T>`,
and a `Type.Typedef` prints as its C name.

## What the checker allows on foreign values

Foreign values flow through the ordinary checker with a handful of dedicated
rules in `types.lua` and `checker.lua`:

* **Member access**: `Ast.VarDot` on a `Type.ForeignModule` resolves through
  `mod.members`; a miss is the compile-time error
  `member '<name>' not found inside module '<mod>'`.
* **Calls**: a foreign function is an ordinary `Type.Function`; the only
  special bit is `vararg`, which relaxes arity to "at least the declared
  parameters" (`#args == nparams or (ftype.vararg and #args > nparams)`).
  The `vararg` field was added for the FFI's sake (PR #174); Titan-defined
  functions always pass `false`.
* **Nullable pointers**: `types.compatible` accepts `Pointer ~ Nil` in both
  directions, so `nil` passes for any pointer parameter and pointers compare
  against `nil`; `types.is_truthy` excludes `Type.Pointer`, so the *checker*
  accepts a pointer as a condition, and the coder's `toboolean` handles it —
  `if fd then ...` compiles and runs (a pointer is truthy iff non-NULL).
  Relational comparison of pointers is rejected
  (`trying to use relational expression`).
* **Typedef transparency**: `types.compatible` unwraps `Type.Typedef`
  through its `_type` on either side; `types.equals` compares typedefs by
  name and pointers structurally.
* **Implicit coercion to `void*`**: `types.coerceable` (via
  `can_coerce_pointer`) accepts any pointer *and any Titan string* where
  `Pointer(Nil)` is expected — why `fwrite(msg, ...)` typechecks against
  `const void *`. One branch tests `source.tag == "Type.Nil"` — missing the
  underscore in `_tag` — so the nil-to-void* *coercion* branch never fires;
  `nil` still passes through `compatible`'s nullable-pointer rule, which is
  why no test notices.
* **Explicit cast**: `types.explicitly_coerceable` permits exactly one cast,
  `void*` → `string`, consumed by the `Ast.ExpCast` handler — the
  `mem as string` idiom. Without it, the error is the spec-checked
  `expected string but found void pointer`; mixing distinct pointer types
  gives `expected pointer to FILE but found pointer to DIR`.

## Code generation for foreign code (`titan-compiler/coder.lua`)

### C types, and why pointers escape the GC

`foreignctype` renders converted types back into C: `Pointer(Nil)` → `void*`,
`Pointer(Typedef T)` → `T*`, other pointers recursively with `*` appended,
`String` → `char*`, anything else
`error("FIXME unknown foreign c type: ...")` (a compiler abort, not a
diagnostic). The general `ctype` function routes `Type.Pointer` through it,
so a pointer-typed Titan local is a *bare C pointer variable*. Pointers are
excluded from `types.is_gc`, so they get no Lua stack slot and the collector
never sees them — correct, since they do not point into the Lua heap (see
[Values and the GC](values-and-gc.md) for the anchoring discipline everything
else follows). `newforeigntmp` declares plain C temporaries for exactly the
`char*` and pointer cases.

### Calls, variables, and the single namespace

`codeforeigncall` emits the **bare C identifier**: the generated call is
`$NAME($CAEXPS)` with `node.exp.var.name` pasted in directly. The Titan-side
module names (`stdio.`, `errno.`) exist only in the checker; in C, all
foreign imports share the translation unit's one namespace — the source
carries `-- TODO catch name conflicts among imports`. `codeforeignvar`
likewise renders a foreign variable or `#define` member as just its C name.
Variadic calls need no marshalling at all: every argument, fixed or extra, is
converted positionally and pasted into the argument list. From the
`fopen`/`fwrite`/`fclose` spec module, the generated native function body is:

```c
FILE* _local_fd_1;
_local_fd_1 = fopen("tmp_test_hello.txt", "w");
TString* _local_msg_1;
/* ... msg = luaS_new(L, "Hello, Titan!\n"), anchored in a stack slot ... */
char* _tmp_2;
_tmp_2 = getstr(_local_msg_1);
((void)fwrite(((void*)(_tmp_2)), tsslen(_local_msg_1), 1, _local_fd_1));
((void)fclose(_local_fd_1));
```

Visible here: the bare names, the `FILE*` local with no GC slot, the string
literal passed straight through, `getstr` for string-to-`char*`, and the
`((void*)(...))` cast materialized from the implicit string-to-`void*`
coercion.

### Converting values at the boundary

`codeforeignexp` converts an expression *into* the foreign world, with four
cases: a foreign call or foreign VarDot is already foreign; an
`Ast.ExpString` **literal** is emitted directly as a C string literal
(`c_string_literal`) with no Lua string ever created; an `Ast.ExpCast` to
`string` (the `mem as string` idiom) emits the inner foreign expression
wrapped in `foreigncast`, which renders exactly `(($CASTTYPE)($CEXP))`;
everything else goes through ordinary `codeexp` plus `nativetoforeignexp`.

`nativetoforeignexp` passes Integer, Float, Boolean and Pointer values
through unchanged (Titan integers are `lua_Integer`, 64-bit — hence `%lld`
in `printf` formats); `nil` becomes the literal `NULL`; a String becomes a
`char*` temporary assigned `getstr($CEXP)` — the Lua-internal macro
returning a pointer to the byte buffer *inside* the `TString` object (Lua's
heap-allocated, immutable, NUL-terminated string representation). The C
function sees Titan's actual string memory, zero-copy, and the lifetime
caveats follow: the buffer is valid only while the `TString` is alive (the
calling convention keeps arguments anchored on the Lua stack for the
duration of the call, but nothing protects a pointer a C function *stores*),
must be treated as read-only, and embedded zero bytes look like the end of
the string from C.

`foreigntonativeexp` converts results back: scalars and pointers pass
through; `Nil` (a `void` return) becomes `"0"` (discarded); a `Type.Typedef`
result recurses on its resolved `_type`; a `char*` result is first
NULL-checked (a NULL pointer — e.g. `getenv` of an unset variable — raises a
clean run-time error rather than dereferencing NULL), then goes through
`makestring`, which renders `luaS_new(L, $VALUE)` — `luaS_new` *copies* the
C bytes into a fresh heap `TString` — and, when not immediately consumed by
an assignment, anchors it in a stack slot
(`$TMPNAME = $CSTR; setsvalue(L, $TMPSLOT, $TMPNAME);`) so the GC cannot
collect it before use. The copy direction explains the ownership story:
Titan never frees the C pointer. (A nullable `char*` still maps to `string`,
not `string?`; that modeling gap stays.) From the `strcpy` spec module:

```c
void* _local_mem_1;
_local_mem_1 = realloc(NULL, 100);                 /* nil -> NULL      */
char* _tmp_2;
_tmp_2 = getstr(_local_h_1);                       /* h's byte buffer  */
TString* _tmp_3 = 0;
_tmp_3 = luaS_new(L, strcpy(((char*)(_local_mem_1)), _tmp_2));
setsvalue(L, _tmp_3_slot, _tmp_3);                 /* anchor the copy  */
free(_local_mem_1);
```

Two more integration points: an `Ast.ExpCast` whose *result* type is
`Type.Pointer` compiles as `codeexp` + `nativetoforeignexp` + `foreigncast`
(Titan-value-to-pointer casts), and a foreign call in statement position
just emits its statements plus `fexp .. ";"`.

### `#include` emission

In `coder.generate`'s first toplevel pass, each `Ast.TopLevelForeignImport`
contributes an include: absolute header paths (`headername:match("^/")`)
become `#include "$HEADERNAME"`, all others `#include <$HEADERNAME>`,
substituted at `$FOREIGNIMPORTS` in the preamble after the Lua-internal
headers and `titan.h` (see [the overview](codegen-overview.md)). The C
compiler thus re-parses the same header the Lua-side toolchain parsed, and
disagreements surface as C compiler errors.

The converted type of `fwrite`'s return is `Type.Typedef` (`size_t`), and
`ctype` handles it through its `Type.Typedef` case, emitting the C type of
the resolved underlying scalar — so storing such a result in a local and
using it (e.g. `return n`) compiles and runs (verified by execution against
glibc's `stdio.h`). Unsupported C types never reach this point: they are
skipped at conversion time (above), so referencing such a member is a clean
`member '...' not found` compile-time error rather than a code-generation
failure.

## Platform constraints and failure modes, summarized

* Compile-time POSIX dependency: `gcc -dM -E`, `cpp -v`, `/dev/null`,
  `LANG=C`. Compiled modules carry no extra run-time dependency beyond the
  libraries they link.
* Headers must be parseable by the built-in preprocessor and grammar;
  failures surface as `failed preprocessing ...` / `failed parsing ...`
  compile-time errors at the import location. But several conditions escape
  as **raw Lua errors** that crash the compiler instead: `unimplemented
  operator` (in `#if`), `unterminated function-like macro`,
  `NYI long double` and `FIXME unknown foreign c type` (in the coder).
* Struct/union contents are stubs; enum values are not stored
  (bare-enum constants are not registered at all); static C
  functions are invisible; `extern inline` definitions are demoted to
  declarations; one flat C namespace with no conflict detection; `#error` is
  ignored.

## `typed.lua`: the disabled run-time-typing DSL

Everything under `c-parser/` is written against `typed.lua` (repo root,
installed as the `typed` rock module), a run-time signature-checking DSL used
nowhere else in the compiler. A definition like

```lua
cpp.initial_processing = typed("FILE* -> LineList", function(fd) ... end)
```

wraps the function with input/output arity and type checks parsed from the
signature string. The type vocabulary covers Lua type names, metatable
`__name` strings (assigned with `typed.set_type(t, "Ctx")` or
`typed.table("CType", {...})`), `"array"` (integer-keyed sequence), `{T}`
element-checked sequences, `T?` optionals, and the output wildcard `"*"`;
violations raise errors shaped
`type error: argument 2: expected Ctx, got table (...)` or
`wrong number of inputs (given N - expects SIG)`.

It ships **disabled**: `typed.lua` calls `typed.off()` just before returning
the module, which makes `typed(...)` return the function unwrapped and turns
`typed.check`/`set_type`/`table` into no-ops. When debugging type confusion
inside the c-parser (the usual symptom: a nonsense CType arriving at
`foreigntypes.convert`), edit that line to `typed.on()` and the signatures
become live assertions; flipping the `FAST` flag at the top skips
per-element sequence checks if the slowdown matters.
