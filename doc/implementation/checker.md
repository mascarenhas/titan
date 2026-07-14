# The type checker

The checker takes the AST the parser built (see
[Lexer and parser](lexer-parser.md)) and produces the typed, *elaborated* AST
the [code generator](codegen-overview.md) consumes. It lives in three files
under `titan-compiler/`: `checker.lua` (the traversal), `types.lua` (type
values and relations), and `symtab.lua` (scoping). Above all: the checker
does not merely *check* — it **rewrites** the AST so that every implicit
conversion, every extra multiple-return value, and every defaulted loop step
exists as an explicit node. The code generator relies on that completely; it
never decides to coerce anything on its own.

## Entry point and contract

```lua
function checker.check(modname, ast, subject, filename, loader)
```

(`checker.lua`, `checker.check`.) It builds a fresh symbol table with
`symtab.new(modname)`, runs the two top-level passes (below), computes the
module's interface type with `makemoduletype`, stores it in `ast._type`, and
returns **`ast._type, errors`** — a `Type.Module` and the error list. The doc
comment above the function still claims a boolean return; it is stale.
Callers test `#errors == 0` (as `spec/checker_spec.lua` does). `loader` is
the import callback (see [Imports](#imports-and-the-loader-protocol)); if
omitted, a stub that fails every import is used.

Errors accumulate: nothing aborts on the first problem. The `errors` table is
an array of formatted strings that also carries `subject` and `filename`
fields. Every error goes through `checker.typeerror`, which formats via
`location.format_error`, so every message a user sees has the shape
`FILENAME:LINE:COL: type error: <message>`. When an expression cannot be
given a type, the helper `invalid(errors, loc, ...)` logs the error and
returns `types.Invalid()`, the error-recovery type, so checking continues.

## The symbol table (`symtab.lua`)

`symtab.lua` is 67 lines and worth reading whole. A symbol table is a stack
of blocks plus one flat side table:

* `blocks` starts as `{ {} }`; `open_block`/`close_block` push and pop, and
  `with_block(body, ...)` wraps a call in a scope. `add_symbol(name, decl)`
  writes into the innermost block; `find_symbol(name)` searches innermost-out.
* `find_dup(name)` checks **only the innermost block**
  (`return self.blocks[#self.blocks][name]`) and is used only for top-level
  duplicate detection. Local declarations just call `add_symbol`, so
  re-declaring a name in the same inner block silently overwrites it, except
  for read-only compiler-synthesized locals such as `L`, which `declare`
  rejects before adding the new symbol.
* `foreign_types` is a **separate namespace** for C typedef names
  (`add_foreign_type`/`find_foreign_type`), populated when a `foreign import`
  is checked, so C type names never collide with Titan symbols.
* `st.modname` is stored at construction and used by `typefromnode` to fully
  qualify nominal type names: the written type `Point` inside module `geo`
  becomes `types.Nominal("geo.Point")`.

One pseudo-symbol uses the table as a side channel: `checkfunc` binds
`"$function"` (not a legal identifier, so it cannot clash) to the enclosing
function node, and the `StatReturn` handler looks it up to find the declared
return types.

## Two passes over the top level

`checker.check` runs `checktoplevel` and then `checkbodies`.

**Pass 1 — signatures** (`checktoplevel`). Visits every top-level node in
order, computing its type without looking at function bodies: `TopLevelFunc`
gets a `types.Function` built from its written parameter/return types;
`TopLevelRecord` builds its `Type.Field` list and registers
`types.Record(fqtn, fields, {}, {}, nfields)` in `types.registry` under
`modname .. "." .. name`; record functions and methods attach themselves to the
registered record type; imports run the loader; variables check their
initializers. Duplicate handling happens here: `toplevel_name(node)` yields
the declared name (the local name for imports; `nil` for methods and
record functions, which have their own clash logic against the record's existing
fields, methods and record functions); a `st:find_dup` hit produces `duplicate
declaration for %s, previous one at line %d` and sets `node._ignore = true`.
Everything downstream — pass 2, `makemoduletype`, the coder — must skip
`_ignore`d nodes; forgetting that is a classic source of crashes.

**Pass 2 — bodies** (`checkbodies`). Checks function, method and record-function
bodies (`checkfunc`, each in a fresh scope; `checkmethod` first synthesizes a
`self` declaration typed as the record's `Type.Nominal`), and validates
record **field types** — deferring those to pass 2 is what makes recursive
and mutually recursive records typecheck, since by then every record of the
module is in the registry. `checkfuncbody` also synthesizes a read-only local
`L` in every function-like body. Its type is `lua_State *` in the C FFI type
family; if a `foreign import` has already introduced `lua_State`, the checker
reuses that type identity, otherwise it creates the same opaque declaration.
After both passes, `makemoduletype` builds the module's interface from the
non-`islocal`, non-`_ignore`, non-import top levels (`TopLevelVar` →
`Type.ModuleVariable`; `TopLevelFunc`/`TopLevelRecord` →
`Type.ModuleMember`). Local record fields, methods and functions are likewise
left out of serialized public record interfaces.

`checker.has_main(ast)` is a post-check used by `titanc` to decide between
building a shared library and a standalone executable: it looks for a
`TopLevelFunc` named `main` with exactly one parameter whose *checker* type
is `{string}` and one return type whose *AST tag* is `Ast.TypeInteger` —
checked type on the parameter side (so it only works after `checker.check`),
raw AST node on the return side.

## The relations in `types.lua`

Three relations drive everything. All are plain Lua functions dispatching on
`_tag`.

### `types.equals(t1, t2)`

Structural where the type is structural, nominal where it is not: Array/Array
compares element types; Map/Map compares keys and values; Function/Function
requires equal arities and pointwise equality of parameters and returns;
Option/Option compares bases; Nominal/Nominal compares **fqtn strings only**
(record contents never participate); Pointer/Pointer compares pointed-to
types and Typedef/Typedef compares names (FFI types); any other same-tag pair
is equal; everything else is not.

### `types.coerceable(source, target)` — every implicit coercion

One big disjunction. True iff any of:

1. `target` is a Pointer and `can_coerce_pointer(source, target)` — which
   requires `target` to be a *void* pointer and `source` to be String or
   another Pointer. (The clause meant to allow `nil → void*` tests
   `source.tag` instead of `source._tag` — a latent typo, so it never fires;
   nil-to-pointer survives only via `compatible`'s nullable-pointer rule.)
2. Integer → Float.
3. Float → Integer (a run-time-checked narrowing).
4. anything-but-Boolean → Boolean (truthiness).
5. anything-but-Value → Value (boxing).
6. Value → anything-but-Value (run-time-checked unboxing).
7. `t → t?` when `equals(source, target.base)`.
8. `t? → t` when `equals(target, source.base)` — forcing, run-time nil check.
9. Nil → any `t?`.
10. `s? → t?` when `coerceable(s, t)` (option-to-option lifting).
11. non-option `s → t?` when `coerceable(s, t)` (coerce, then wrap).
12. option `s?` → non-option `t` when `coerceable(source.base, target)` — the
    base must itself coerce to the target. This is what admits, e.g.,
    `float? → integer` (force, then narrow — initializing an `integer` local
    from a `{float}` element compiles and runs). It is correctly directional:
    `boolean? → integer` is rejected, since `coerceable(boolean, integer)` is
    false (truthiness only goes *to* Boolean), so `local i: integer = b` with
    `b: boolean?` is a clean type error rather than a coercion the coder
    cannot honor.

Note that `coerceable` is **irreflexive**: no clause matches two equal
non-Value types. That matters for `as` casts and `checkmatch`, both below.

### `types.compatible(t1, t2)` — gradual-typing consistency

Checked in order: `equals` → true; Typedefs unwrap and recurse;
Pointer-vs-Nil in either order → true (nullable pointers);
`explicitly_coerceable` → true; **`Type.Value` on either side → true** (the
gradual "value is consistent with everything" rule); Array/Array and Map/Map
recurse with `compatible` (so `{value}` is compatible with `{float}` —
Value-consistency reaches through containers); Nominal/Nominal compares fqtns
(no recursion into record bodies); Function/Function requires equal arities
and pointwise compatibility; otherwise false. The relation is symmetric in
every clause except `explicitly_coerceable`, which is tested in one order
only: `compatible(void pointer, string)` holds but `compatible(string,
void pointer)` does not (verified).

### `types.explicitly_coerceable(source, target)`

Exactly one rule: a *void pointer* may become a `string`, and only with an
explicit `as` cast. It also appears inside `compatible`, which is why `as`
between those types passes the compatibility half of the cast check.

Where each relation is consulted — `coerceable`: `checkmatch`, `trycoerce`,
the `as`-cast check. `compatible`: `checkmatch`, `==`/`~=`, the `as`-cast
check. `equals`: inside `coerceable`/`compatible`/`can_coerce_pointer`,
relational operators, `or` option-defaulting, and three assertions in
`coder.lua`. `explicitly_coerceable`: inside `compatible` and the `as`-cast
check.

### `checkmatch` — the gatekeeper

```lua
local function checkmatch(term, expected, found, errors, loc)
    if types.coerceable(found, expected) or not types.compatible(expected, found) then
        local msg = "types in %s do not match, expected %s but found %s"
```

Read the condition twice: it errors when the types are *incompatible*, **or
when they are still `coerceable`**. The second arm encodes the central
invariant: by the time `checkmatch` runs, every coercion *allowed* in this
context has already been materialized as a cast node (so `found` already
equals `expected`, and irreflexivity makes the first arm false). A
still-coerceable pair reaching `checkmatch` means the context deliberately
did not coerce — numeric `for` bounds are the canonical example — and that
is an error. The `term` string names the context in the message
(`assignment`, `return`, `array indexing`, `argument 2 of call to function
'f'`, `'for' start expression`, …).

A pair that is compatible but *not* coerceable — say `{value}` where
`{float}` is expected — passes `checkmatch` with **no cast node at all**; the
run-time checks for such gradually-typed values are emitted by the coder at
access sites (see [Code generator: constructs](codegen-constructs.md)).

## Rewriting the AST

This is the load-bearing design. **Invariant:** after `checker.check`
succeeds, every implicit conversion is an explicit `Ast.ExpCast` node, every
consumed multiple-return value beyond the first is an explicit `Ast.ExpExtra`
node, every numeric `for` loop has an explicit step expression, and every
generic `for` loop has hidden iterator tuple/call declarations. The coder
generates conversions *only* from `ExpCast` nodes and never consults
`coerceable`; if the checker fails to materialize a cast, the coder silently
emits code for the wrong type.

### `trycoerce`, `tryforce`, `trytostr`

`trycoerce(source, target, errors)` is the workhorse: if
`types.coerceable(source._type, target)`, it wraps the node in a synthesized
`ast.ExpCast(loc, exp, target)` with `_type = target`; otherwise it returns
the node unchanged. Option types make the synthesis recursive:

* An Option-to-Option conversion is one cast that propagates nil and converts
  a present value between the base types.
* If the source is an Option and the non-option target is neither Boolean nor
  Value, it first synthesizes an inner cast from `t?` to `t` (the runtime
  nil-check, or "force"), then recursively coerces that to the target. With
  `of: float?`:

  ```lua
  local i: integer = of
  -- initializer becomes Cast(Cast(of, float), integer)
  ```

  Boolean and Value targets skip the force on purpose — an option's nil-ness
  *is* its falsiness, and boxing to `value` needs no unwrapping.
* If the target is an Option, a Nil or Value source becomes one direct cast to
  that option. This preserves nil and, for Value, checks a present value
  against the option's base. Other sources coerce to the base first and then
  wrap: `ExpCast(loc, trycoerce(source, target.base), target)`. So
  `local x: float? = 1` becomes `Cast(Cast(1, float), float?)`, while returning
  a `value` from a `string?` function becomes `Cast(value, string?)` rather
  than `Cast(Cast(value, string), string?)`.

`tryforce(node)` wraps any Option-typed node in a cast to its base — the
implicit "must not be nil here" check. It is applied at: `for` bounds;
un-annotated `local` and top-level-variable inference (so inference never
produces an option); `VarDot` receivers (`p.x` on a `Point?` forces it);
`VarBracket` indexees (indexing an `{t}?`); and the operands of `#`, unary
`-`, `~`, `..`, relational comparisons, arithmetic, `/`, `^`, and bitwise
operators — but *not* to method-call receivers or `==`/`~=` operands
(equality keeps options, below). `trytostr(node)` wraps Integer- or
Float-typed nodes in a cast to String; only `..` concatenation uses it.

The contexts that call `trycoerce` are: declaration initializers, assignment
RHS, returns, call arguments, index expressions, initializer-list entries,
record fields, top-level variable initializers, generic-`for` tuple slots
and visible variables, plus the operator-specific promotions (catalogued in
the [type system chapter](../language/types.md)). A contributor adding a
context must call `trycoerce` *before* `checkmatch`, or legal programs will
be rejected by the still-coerceable arm.

### `ExpExtra` — materializing multiple returns

A call node gets `node._type = rettypes[1]` and `node._types = rettypes`.
Wherever a multi-value context consumes a call in last position —
declarations, assignments, returns, call arguments, array initializers — the
checker appends synthesized `ast.ExpExtra(loc, exp, index, _type)` nodes, one
per extra value, each then coerced and matched like any expression:

```lua
local a, b = f()   -- f(): (integer, integer)
-- node.exps becomes { ExpCall(f), ExpExtra{exp = <that call>, index = 2} }
```

The coder compiles `ExpExtra` by reading the corresponding out-parameter of
the call (see [the calling convention](codegen-overview.md)). One asymmetry
remains: map initializers have no expansion code, so extra values there are
silently truncated. The `?` inference marker carries through to the extras of
a multi-return declaration, just as on the head: `local a, b? = f()` makes
`b` an option (`optionize(exp._type)`), while a marker-less tail variable is
forced like any inferred local.

### Call argument adjustment

`checkargs` owns the upward adjustment of Titan function calls. After the
ordinary argument expressions and any trailing multi-return expansion have
been checked, a fixed-parameter deficit is filled by appending synthesized
`Ast.ExpNil` nodes. Each synthesized nil is passed through `trycoerce` and
`checkmatch` against the corresponding parameter type, exactly like a
written `nil` argument; this is why omitting an `integer` parameter remains
a compile-time type error, while omitting an `integer?`, `value` or
`boolean` parameter is accepted under the existing coercion rules. If the
call has too many arguments, `checkargs` still reports the arity error and
does not drop anything.

The missing-argument rule is deliberately limited to Titan function calls.
Foreign C function calls and C pseudo-constructors pass `allow_missing=false`
to `checkargs`, preserving C-style arity. A trailing `...` into a
non-variadic Titan call is still expanded with `ExpDotsIndex` nodes; for
call argument slots that can accept nil, the synthesized indexed read uses
the nil-fill mode so an under-supplied runtime variadic tail behaves like
the same short call written without `...`. The variadic-callee start-adjust
path applies the same present-element coercion and nil-fill decision when
it borrows fixed parameters from a forwarded `...`.

### Default `for` step

`checkfor` synthesizes a literal `ExpInteger(loc, 1)` or `ExpFloat(loc, 1.0)`
(matching the control variable's type) into `node.inc` when the step is
missing, so the coder always sees three bound expressions. The bounds
themselves are `tryforce`d but **never `trycoerce`d** — they are
`checkmatch`ed directly against the control type, so `for i = 1, 10.0` is a
compile-time error rather than a promotion (the old manual claimed
otherwise; this describes the implementation).

### Generic `for` tuple elaboration

`checkforin` turns `for decllist in explist do block end` into an
elaborated `Ast.StatForIn` that codegen can lower without type decisions.
It first checks the written expressions, expands a trailing multi-return
call if present, adjusts a trailing `...` through the same fixed-slot
`ExpDotsIndex` machinery used by locals/returns/calls, errors on more than
four tuple values, and pads missing slots with typed `Ast.ExpNil` nodes.
The four slots are iterator, state, initial control, and close.

For `iter, ...`, the vararg spread is adjusted only through the tuple slots
the iterator needs (state and initial control), then the remaining tuple
slots are padded with static nil. Writing `iter, state, init, ...` reaches
the fourth slot and can supply the close function from the spread.

The iterator slot must resolve to a callable shape: a non-variadic
`Type.Function`, a `value` coerced to a synthesized function type, or a C
function pointer/foreign function viewed through its C signature. The
synthesized type for a `value` iterator uses the non-`nil` state/init slots
as zero, one, or two parameter types, and uses the visible declaration list
as return types, filling unannotated positions with `value` and optionizing
the first return. The iterator returns at least one value. Its first return
is the control result and must be nil-capable: an option type, `value`, a
nullable C pointer, or a raw C `TValue`; `nil` alone and non-nil-capable
concrete types are rejected. State and initial control are coerced and
matched against the iterator's first and second parameters when those
parameters exist.

The close slot must be `nil` or another callable shape. A `value` close slot
is coerced to a synthesized close type using the state slot as its single
parameter when the state is not statically `nil`, otherwise to a zero-arg
close type; the synthesized close has no returns. Statically typed close
functions and C function pointers may accept zero or one parameter. If they
accept one, the state value must coerce to it. Any close returns are
accepted but discarded.

The checker then synthesizes:

* `_tuple_decls`: hidden declarations holding the four adjusted tuple
  values, so `<explist>` is evaluated once.
* `_result_decls`: hidden declarations holding every iterator return value.
* `_init_call` and `_next_call`: synthesized calls through the hidden
  iterator. Function values go through the ordinary function-value path; C
  function pointers carry `_c_pointer_call` so codegen uses the FFI pointer
  path. The update call forces the previous control result before coercing it
  to the iterator's second parameter, because loop entry has already proved
  it is not nil.
* `_close_call`: an optional synthesized call through the hidden close
  function, marked `_voidok` because close returns are ignored.
* `_visible_stat`: a synthesized `StatDecl` that initializes the
  user-written variables from `_result_decls` on each iteration.

The visible variables are declared in the loop body's scope and marked
`_forcontrol`, making assignment to them the same compile-time error as for
numeric `for` variables. The first visible variable is initialized from a
forced control result. Later variables are initialized from matching return
positions; if a position is missing, only an explicitly annotated variable
can receive the synthesized `nil`, because an unannotated declaration would
have no type to infer.

### `ExpAdjust` — truncation to one value

The parser wraps a parenthesized *call* in `Ast.ExpAdjust`. The checker's
handler propagates `exp._type` but deliberately not `_types`; since
`ExpExtra` expansion triggers on `_types`, `(f())` is truncated to exactly
one value in every multi-value position — Lua's parenthesis adjustment,
implemented as the *absence* of a decoration.

## Option-type machinery

Two helpers maintain the option invariants:

* `optionize(t)` returns `t` unchanged when it is already an Option **or is
  `Type.Value`** (so `value?` ≡ `value` — a `value` already includes nil);
  otherwise `types.Option(t)`.
* `deoptionize(t)` unwraps one level and *asserts* that the base is not
  itself an Option. Because options are only ever constructed through
  `optionize`, `Option.base` is never an Option — code may rely on it.

De-optionization is applied silently where nil-tolerance lives in the
operation, not the type: array element types (`{integer?}` means
`{integer}`), map value types, and initializer-list context types. Map *key*
types reject Nil and Option with errors. In the other direction, every
array/map indexing **read** is optionized: `arr[i]` has type `elem?` and
`m[k]` has type `values?` — and since the same type is used when the element
is an assignment target, writing `nil` into an element (deletion) typechecks.

Inference never produces an option unless asked: in an un-annotated `local`,
the initializer is `tryforce`d before its type is copied; the parsed `?`
marker (`local y? = arr[1]`) flips that to `optionize(exp._type)`:

```lua
local x = arr[1]   -- x : integer  (forced)
local y? = arr[1]  -- y : integer?
```

Equality keeps options rather than forcing them. In `==`/`~=`: if either
side is Value, both are boxed to Value; **else if either side is an Option,
each side is lifted to the option of its own type** (`s? == s` lifts the
right side to `string?` and compares equal types) — this lift is PR #250's
fix; before it the coerced nodes were assigned to nonexistent fields and
never landed. Numbers are then **not** promoted: a mixed Integer/Float pair
(either order, and likewise two options over Integer/Float) is allowed through
without coercion — codegen compares them by mathematical value, exactly as Lua
does — and any remaining incomparable pair errors. The result
is always Boolean.

`or` implements option defaulting: when the left side is `t?` and the right
side's type equals `t`, the whole expression has type `t` (`of or 1.0` with
`of: float?` is a `float`). The full `and`/`or` case ladders (Boolean
contexts, statically truthy/falsy left sides, optionizing the right side of
`and`, Value mixing) live in `checkexp`'s `Ast.ExpBinop` handler and are
specified case-by-case in [option types](../language/option-types.md).

## Closures: capture analysis and lambda inference

Anonymous functions (`Ast.ExpFunction`) add two pieces of work to the
checker: deciding which enclosing variables each lambda **captures** (and
whether each captured variable is mutated, which the coder needs to choose
the boxed representation), and **inferring** a lambda's missing parameter
and return types.

### Function-nesting tracking

The symbol table is a flat block stack with no notion of function
boundaries, so the checker keeps its own. `checker.check` initialises
`func_stack = {}` at the top (it is reset per check, unlike the
module-global `loop_depth`). A frame `{ depth, captures = {}, capture_set
= {} }` is pushed at the **very top** of the body-check for `checkfunc`,
`checkmethod`, and the `Ast.ExpFunction` handler — *before* the
parameters/`self` are declared, so they are stamped at the function's own
depth — and popped after the body. Every local/param/`self` `Decl` records
`decl._funcdepth = #func_stack` (locals in the single `declare` helper;
params/`self` in `checkfunc`/`checkmethod`).

The lambda handler must additionally open its **own** `with_block` and
`add_symbol("$function", node)` inside it before checking the body (and set
the lambda node's `_type` first, so `StatReturn` can find the return
types). `checkfunc` gets away with adding `$function` to the caller's block
only because `checkbodies` wraps it in `with_block`; a lambda has no such
wrapper, so a naïve copy would leak `$function` into the enclosing scope.

### The capture flags

For each in-function local/param `Decl`:

* `decl._assigned` — set when the variable is assigned after declaration
  (the pre-existing flag, set in `checkvar`). The numeric-`for` control
  variable's implicit increment does **not** set it, so a captured `for`
  variable stays immutable (and thus by-value, fresh per iteration).
* `decl._captured` — set when the variable is referenced (read or write)
  from a function nested inside its declarer.
* `decl._used` — **forced true** when a decl is captured, so a variable
  only *written* (never read) by an inner function still passes
  `StatDecl`'s `_used` gate and gets its box allocated.

Capture detection lives in **one place**, the `VarName` visitor, which
uniformly covers reads and assignment targets. When a resolved name is a
local/param (`decl._tag == "Ast.Decl"` — `TopLevelVar`/`TopLevelFunc`/
module members resolve to other node tags and are therefore never
captured) and `decl._funcdepth < #func_stack`, it is a capture: set
`_captured`/`_used`, and add the decl (first-seen order, deduped via
`capture_set`) to the `captures` list of **every frame in the inclusive
range `[decl._funcdepth + 1 .. #func_stack]`** — every function from the
one just inside the declarer up to *and including* the current innermost
one. The inclusivity is what threads a transitively-captured variable
through the intervening lambdas all the way to the deepest one that uses
it; a "strictly between" interval would drop the innermost frame and miss
the actual user. The pass is a single in-order traversal, so by the end of
`checkbodies` every flag and capture list is final, before codegen.

### Lambda type inference: checking vs synthesis mode

The `Ast.ExpFunction` handler reads the 4th `context` argument every
`checkexp` visitor receives (the expected type). If `context` is a
`Type.Function` whose arity matches `#node.params`, the lambda is in
**checking mode**; otherwise in **synthesis mode**. This is exactly the
`local x: T = exp` (checking) versus `local x = exp` (synthesis)
distinction, lifted to lambdas. **Both the parameter types and the return
type are taken from this expected type** — symmetric, context-only
inference; neither is reverse-engineered from the lambda's body.

* **Parameters.** An annotated parameter uses its annotation. An
  unannotated one takes `context.params[i]` in checking mode, and in
  synthesis mode is the clean error `cannot infer type of parameter 'x'`.
* **Return.** An explicit `node.rettypes` list (including `{}` for an
  explicit `: ()`) is used as written. The parser distinguishes *no return
  annotation* from `: ()` with a sentinel, so the handler can tell them
  apart. With no annotation: in checking mode the return comes from
  `context.rettypes`; in synthesis mode it defaults to `{}` (zero-return
  `()`), exactly the default an unannotated top-level function gets.

So `node._type.rettypes` is always known *before* the body is checked. The
body's `return`s are never inspected to synthesize a return type — they are
checked/coerced against the now-fixed return types in `StatReturn`, exactly
as a top-level function body is. A synthesis-mode lambda whose body does
`return <expr>` is therefore the documented zero-return footgun: a clean
arity error (`returned N value(s) but function expected 0`), consistent
with an unannotated top-level function.

Because the return types are fixed before the body is checked, the
all-paths-return rule runs unconditionally inside `checkfuncbody` (no
special deferral for lambdas), so a lambda with a non-`nil` return whose
body can fall through gets the usual `function can return nil but return
type is not nil` error, prompting an annotation. After the handler returns
with `_type = node._type`, the surrounding context applies its usual
`trycoerce`/`checkmatch` against the lambda's target.

## Per-construct notes for contributors

* **The `context` parameter.** `checkexp(node, st, errors, context)` threads
  an *expected type* down the tree. It is not inference: literals ignore it
  (`10` in a float context is still an Integer that then gets a cast), but
  `Ast.ExpInitList` needs it to decide what `{ ... }` *is* — the context is
  `deoptionize`d, its tag picks the array/map/record branch, and only a
  Nominal context permits a record constructor (`no context to provide type
  for record constructor`). With no useful context the shape decides
  (bracketed keys → map, named fields → record error, otherwise array; an
  empty `{}` defaults to `{integer}`). A Boolean context also switches
  `and`/`or` into plain boolean mode.
* **First-class functions, closures, and bound methods.** These are now
  *implemented*, so the points that historically rejected them are acceptance
  points. Referencing a name whose type is `Type.Function` as a value
  (`Ast.ExpVar`) yields a function value; calling a function *value* — a callee
  that is not a `VarName`/`VarDot` resolving to a top-level function, module
  member or static (`Ast.ExpCall`) — typechecks against the function type;
  writing a function *type* in an annotation (`g: (integer) -> integer`) is
  handled by `typefromnode`'s `Ast.TypeFunction` handler and produces a
  `Type.Function`; and assigning a value into a function-typed variable is
  allowed. An `Ast.ExpFunction` (an anonymous function) typechecks to a
  `Type.Function`, with parameter and return types inferred where annotations
  are omitted, and its body captures enclosing locals (see
  [Closures: capture analysis and lambda inference](#closures-capture-analysis-and-lambda-inference)).
  A bare `obj:method` (no call) typechecks to a *bound method reference*: the
  method's `Type.Function` with the implicit `self` removed. What the checker
  **still rejects**, all clean type errors: assigning to a function *name* (you
  cannot rebind a function); taking a *foreign* (C FFI) function as a value or
  binding a foreign method (it can only be called by name — see
  [the FFI chapter](../language/ffi.md)); a method reference on a non-record
  receiver, or to a non-existent method; using a record type or a module as a
  value; and a top-level `local x = function … end` (its initializer is not a
  constant, so `isconst` rejects it as `top level variable initialization must
  be constant`).
* **Conditions are not coerced.** `if`/`while`/`repeat` conditions are
  checked with a Boolean context but never `trycoerce`d or `checkmatch`ed:
  any type is a legal condition, and truthiness is the coder's problem.
  `repeat`'s condition is checked inside the body's scope, so it can see the
  body's locals.
* **`as` casts.** A user-written `Ast.ExpCast` errors (`cannot cast '%s' to
  '%s'`) unless the pair is `explicitly_coerceable` or `coerceable`, *and*
  `compatible`. Because `coerceable` is irreflexive, an identity cast is
  rejected by this path — `x as integer` when `x` is already an integer
  errors `cannot cast 'integer' to 'integer'` (verified); no spec asserts
  that this is intended.

## The "always returns" analysis

Every `checkstat` handler returns whether the statement is guaranteed to
return from the enclosing function. `StatReturn` returns `true`; `StatIf`
returns `true` only if every then-block returns *and* an `else` exists and
returns; loops and everything else return `false`/`nil`, except `StatBlock`
— a bare `do … end` propagates its own fold, so `do return 1 end` counts as
returning (verified). `checkblock` folds
the results with `ret = ret or checkstat(stat, st, errors)` — and note the
short-circuit: once `ret` is true, **later statements in the block are not
visited at all**. A plain `return` can only be a block's final statement (the
grammar enforces it), but an always-returning `if`/`else` mid-block makes the
case reachable. *Limitation:* statements after such an `if` are dead code and
go completely unchecked — a type error placed there is not reported (verified
experimentally). The checker performs no dead-code analysis to flag or prune
them.

`checkfunc` consumes the result: if the body does not always return and the
function has a declared return type (`rettypes` is non-empty and not a single
`Type.Nil`), it reports `function can return nil but return type is not nil`.
Functions declared without a return annotation default to **zero returns**
(`() -> ()`, returning nothing as in Lua), so a procedure needs no `return`
and is never flagged.

## Imports and the loader protocol

`Ast.TopLevelImport` is checked by `checker.checkimport(modname, loader)`.
The loader contract is:

```lua
loader(modname)  -->  ok, moduletype_or_error, errors
```

On success, the import node's `_type` is the returned `Type.Module`, and
errors found while checking the dependency propagate into this module's
error list. `checkimport` then walks the module's members and registers each
imported record into `types.registry`: it unwraps the `Type.ModuleMember`
wrapper and, when the underlying type is a `Type.Record` (or
`Type.Interface`), stores it under its fqtn. This is what makes a record
imported from a `.so`-only dependency — one with no `.titan` source to
re-check — usable by nominal type. For a dependency *with* source the same
registration also happens as a side effect of the dependency's own
`checker.check`, which the loader runs recursively: the `TopLevelRecord`
visitor writes into the process-global `types.registry`. A `Type.Nominal`
carries *only* its fqtn string and
resolves through the registry at every use, so the qualified type
`geo.Point` (parsed as `Ast.TypeQualName`, converted by `typefromnode` to
`types.Nominal("geo.Point")`) means something only because checking module
`geo` registered `"geo.Point"`. On loader failure the import errors with
`problem loading module '%s': %s`.

Two real loaders exist in `driver.lua`:

* `driver.defaultloader` caches results in `driver.imported` and detects
  cycles by planting a `CIRCULAR_MARK` sentinel in the cache before recursing
  (a re-entry finds the mark and fails with `circular reference to module`).
  Dependencies with `.titan` source are recursively parsed and checked.
  `.so`-only dependencies recover their interface by loading the compiled
  module's `<mangled>_types` symbol — a string of nested constructor calls
  produced by `types.serialize` — and evaluating it with
  `load("return " .. s, modname, "t", types)`, the `types` module itself
  serving as the environment. C FFI types are *not* serializable
  (`types.serialize` raises on any type tree containing one), so imported C
  types cannot cross a compiled-interface boundary. Local record declarations
  and local record members are omitted from the serialized interface; exported
  records still serialize their total `nfields` count and each public
  `Field.index`, so public fields keep their real `Udata` slot even when local
  fields were skipped.
* `driver.tableloader` is the in-memory variant for tests; it deliberately
  serializes and re-loads every module type, so the round-trip is exercised
  by every import test in the suite.

`foreign import` is checked separately (`Ast.TopLevelForeignImport`): it runs
the C parser pipeline and converts each declaration with
`foreigntypes.convert`. C values become members of a `Type.CModule`; C type
declarations become `type_members` plus entries in the symbol table's
`foreign_types` namespace, which is what lets local annotations such as
`c.size_t` resolve (see [FFI internals](ffi-internals.md)).

After the module interface is built, export validation rejects any public type
tree that mentions a local record type, and any public type tree that mentions a
C FFI type. For records, the walkers skip local fields, local methods and local
record functions before applying the C-type check, which is why an exported record may
have a private C-typed field as long as that field is local.

## Process-global state

Two pieces of mutable state outlive a `checker.check` call, and any test or
tool that checks more than one module (or the same module twice) must reset
them: `types.registry`, the fqtn → `Type.Record` map (stale entries make
nominal types from a previous run resolve in the next one), and
`driver.imported`, the import cache, including any `CIRCULAR_MARK` sentinels
left by a failed run. The suite's helpers do exactly this
(`types.registry = {}` and `driver.imported = {}` at the top of
`run_checker`-style functions); new specs must follow the pattern. The parser
adds a non-reentrancy hazard of its own (`THIS_FILENAME`), described in
[Lexer and parser](lexer-parser.md).
