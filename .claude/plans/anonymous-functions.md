# Anonymous Functions with Lexical Closure — Implementation Plan

> Status: **reviewed & approved-to-build (v3).** Expands the user's 12-point
> outline into a full design + implementation + testing plan, grounded in the
> current code (post first-class-functions, `master` @ `6988960`), **de-risked by
> a dynamic workflow** (4 C experiments vs the real Lua 5.5 tree + 5 adversarial
> reviews), and updated for the user's review decisions: box `f` = **trap stub**
> (D3b); **lambda type inference** for params + return (D1/D6); **bound instance
> methods** as first-class values (§4.6); and a **multi-agent PR review** after
> implementation (Part 9, step 7). Open/standing decisions are in Part 8; the only
> non-finalized one is the bound-method *surface syntax* (D7, proposed
> `obj:method`). Raw evidence in the Appendix.

## Context

First-class functions already landed (PR #12,
[`first-class-functions.md`](first-class-functions.md)). That work gave Titan:

- `Type.Function` with full `equals`/`compatible`/`tostring`/`serialize`/`is_gc`
  (`types.lua`), the boxed `TValue` representation (`ctype(Type.Function)=TValue`,
  `coder.lua:547`), and the function-type **tag** publish/recover machinery
  (`function_type_tag`, `coder.lua:159`).
- The **two-entry-point** model: each Titan function emits a *native* entry
  `RETTYPE f(lua_State *L, CClosure *_mod, [self,] params…, outparams…)`
  (`function_sig`, `coder.lua:562`; `codefuncdec`, `coder.lua:2944`) and a *Lua
  entry* wrapper `static int f_lua(lua_State *L)` (`genluaentry`, `coder.lua:2837`).
- Function **values** are `CClosure`s with `upvalue[0]=_mod`, `upvalue[1]=type
  tag` (light userdata), `upvalue[2]=native entry ptr` (light userdata); the Lua
  entry is the `CClosure`'s `f`.
- The **two call paths** through a value (`codevaluecall`, `coder.lua:1283`): a
  fast path (tag matches → unboxed native call through a function pointer) and a
  generic path (`luaD_callnoyield` through the Lua stack).
- **Stable identity** for top-level functions/statics via shadow `_mod` upvalue
  slots (`allocate_upvalues`, `coder.lua:3468`; `node._closure_upvalue`).

Anonymous functions extend exactly this machinery. The headline additions are
(a) an extra native-ABI parameter `_fn` so a function can reach its own closure's
captured upvalues, and (b) a capture analysis + a boxed-variable representation
so closures can read and **mutate** variables of an enclosing function.

This work also adds **bound instance methods as first-class values** (a method
reference closure capturing `self` — §4.6), a small extension that reuses the
closure machinery. Still out of scope: foreign/FFI functions as values
(unchanged from the first-class spec).

**All runtime assumptions were empirically validated** (Appendix A): the
box (a 1-upvalue `CClosure` cell) + `_fn` ABI + closure-fast-path + end-to-end
counter all work on real Lua 5.5 internals, including generational GC and an
assertions (`-DLUAI_ASSERT`) build.

## The 12-point outline → how this plan realizes each

| # | Outline point | Realization |
|---|---|---|
| 1 | Extra param after `_mod` receiving the function closure | `_fn` in `function_sig`/`codefuncdec`/`genluaentry` — §4.1 |
| 2 | Static top-level calls pass NULL for it | `codecall` direct path passes `NULL` — §4.1 |
| 3 | Value calls pass the value itself | fast path passes `_vc_callee` — §4.1 |
| 4 | Lua/generic entry has the value and passes it | `genluaentry` binds `_fn = clCvalue(s2v(func))` — §4.1 |
| 5 | Two flags per local (assigned-after-decl, captured), set in checking | `_assigned` (exists) + `_captured` (new) — §3 |
| 6 | both-flags vars → boxed; box is GC, anchored on stack | **CClosure-cell box** (1 upvalue, trap-stub `f`) anchored in a slot — §2.1, §4.2 |
| 7 | reads follow the pointer/unbox; writes update the boxed value | `getslot`/`setslot` on `&box->upvalue[0]` + `luaC_barrier` — §4.2 |
| 8 | captured-not-mutated OR mutated-not-captured → current rep | gating `decl._captured and decl._assigned` — §2.1 |
| 9 | local function = fresh CClosure; first 3 upvalues + one per captured var | closure-creation codegen — §4.3 |
| 10 | boxed captures: copy the box pointer, access through it | `setclCvalue` copies the box `CClosure*`; native reads `clCvalue(&_fn->upvalue[i])` — §4.3/4.4 |
| 11 | non-boxed captures: copy by value (immutable) | `setslot` copies the value — §4.3/4.4 |
| 12 | native + Lua entries like top-level; **no stable identity** | hoisted entries, no shadow slot — §4.3 |

---

## Part 1 — Language spec (v1)

### Syntax

A new **function expression**, like a top-level function minus the name and
`local`, but with **optional** parameter and return annotations:

```
function (p1[: T1], …, pn[: Tn]) [: rettype] <block> end
```

**Type inference (resolved, D1+D6).** Per the user's call, lambdas infer missing
parameter and return types — this parallels Titan's existing inference for
`local x = exp` (synthesize when no expectation, check when there is one) and is
*not* a departure from explicit typing. Two modes (§3 has the algorithm):

- **Parameter types**: an annotated param uses its annotation; an *unannotated*
  param is inferred from the **expected function type** (the `context`: the slot/
  argument/return position the lambda flows into). With no usable context, an
  unannotated param is a clean compile error ("cannot infer type of parameter
  'x'; annotate it or use the lambda where its type is known").
- **Return type**: an explicit annotation is used as-is; otherwise it is taken
  from the context's return types if available, else **inferred from the body's
  `return` statements** (unified across all returns; no returns → zero-return
  `()`).

Note the lambda grammar must distinguish *no return annotation* (→ infer) from an
explicit `: ()` (→ zero-return), so it uses a `lambdarettypeopt` that yields a
sentinel (`false`) when absent rather than `rettypeopt`'s `{}`.

Grammar: add a `funcexp` alternative to `simpleexp` (`parser.lua:416-423`), with a
lambda-specific param list (optional `: type`) and return-opt. The keyword
`function` is reserved (`lexer.lua`), so the alternative is unambiguous;
empirically validated (Appendix B):

```
lambdaparam     <- (P NAME COLON type) -> typeddecl  /  (P NAME) -> inferreddecl
lambdaparamlist <- {| (lambdaparam (COMMA lambdaparam^DeclParList)*)? |}
lambdarettypeopt<- (P (COLON rettype^TypeFunc)?) -> lambdarettypeopt  -- false when absent
funcexp   <- (P FUNCTION LPAREN^LParPList lambdaparamlist RPAREN^RParPList
                 lambdarettypeopt block END^EndFunc)    -> ExpFunction
simpleexp <- … / funcexp / suffixedexp / prefixexp
```

A lambda is a **`simpleexp` only**, *not* a `prefixexp`. Therefore **direct
application `function()…end(x)` is unsupported**; the parenthesized form
`(function()…end)(x)` works because the surrounding parens (`prefixexp <- '('
exp ')'`) make the result a `prefixexp` that `suffixedexp` can then apply (D5).
The reused error labels `LParPList`/`RParPList`/`EndFunc` already exist in
`syntax_errors.errors` (shared with `toplevelfunc`); no new labels needed.

> **Parser limit (documented):** deeply nested lambdas hit LPeg's "subcapture
> nesting too deep" at roughly 7 levels (Appendix B). Document the bound; tests
> exercise a modest depth (3–4). Not a practical concern for real code.

### AST

Add to `ast.lua`:

```lua
ExpFunction = {"loc", "params", "rettypes", "block"}
```

(`params` = `{Decl}`, `rettypes` = `{TypeNode}`, `block` = `StatBlock` — same
shapes as `TopLevelFunc`.) Adding an `Exp` tag requires updating the
`checkexp`/`codeexp` chains and `make_visitor` users (CLAUDE.md `_tag` convention).

### Semantics

- A function expression evaluates to a **fresh** function value each time it is
  reached (point 12 — no stable identity).
- It **captures by reference** any enclosing-function local/param it uses that is
  *mutated* (boxed → shared mutable state), and **by value** any it uses that is
  *never mutated* (copied; observationally identical because it never changes).
  Top-level (`_mod`) variables and other modules' members are reached through
  `_mod` as today and are **not** captured (point 5: "not for local module
  members").
- Closures are full `Type.Function` values: storable in locals/params/fields/
  arrays/maps, passable, returnable, callable through both paths, crossable
  to/from Lua — all via the existing first-class machinery.
- **Equality**: `==`/`~=` on function values compiles to raw `CClosure` pointer
  comparison (`coder.lua:~2348`). This is well-defined for lambdas: the *same*
  evaluated closure compares equal to itself; two distinct evaluations of the
  same `function…end` are distinct objects → not equal. Document this (no code
  change needed); it is the only sane meaning given point 12.
- Zero-return `()` semantics, `value`↔function casts, and Lua-interop rules are
  inherited unchanged.

### What stays an error / out of scope (v1)

- **Top-level `local x = function…end`** is rejected: a `TopLevelVar` initializer
  must be constant, and a lambda is not. Add an `Ast.ExpFunction` arm to
  `isconst` (`checker.lua:1431`) returning `false`, so this yields the existing
  clean "top level variable initialization must be constant" error rather than
  crashing codegen (BLOCKER from review R4). Lambdas live only inside function
  bodies.
- Foreign functions as values (unchanged). **Instance methods *are* now first-
  class** as bound `self`-capturing values (§4.6).
- **Nested `local function f() … end` statements**, and thus *direct* nested
  recursion (D2). A self-reference inside an anonymous `local f = function…end`
  is a clean compile-time "variable not declared" error — the name `f` binds only
  *after* its initializer is checked (`StatDecl`), so the inner reference does not
  resolve to it. Documented limitation, not a silent miscompile.

---

## Part 2 — Representation & runtime design

### 2.1 The variable box ("UpVal") — a 1-upvalue `CClosure` cell

The outline says "closed UpVal object." The realization is a **`CClosure` with
exactly one upvalue and a trap-stub function pointer**, used purely as a heap cell.
The boxed value lives in `box->upvalue[0]` (a `TValue`). The box is internal to
Titan and **never flows into Lua code** (it is the storage of a captured local,
not a function value), so it needs none of the Lua-facing features a `Udata`
carries (the optional metatable) — that slot would be pure waste.

**Why a `CClosure` cell, not a literal `UpVal` and not a `Udata` (resolves D3 —
empirically; Appendix A):** three candidates were built and GC-stressed under
incremental, generational, and assertions (`-DLUAI_ASSERT`) builds:

| Box | Size | All GC modes? | Mutation barrier |
|---|---|---|---|
| literal closed `UpVal` | 40 | **no — SEGFAULTs under generational GC** | n/a |
| **`CClosure` cell (trap-stub f)** | **48** (`sizeCclosure(1)`) | **yes** | forward `luaC_barrier` |
| `Udata` (`nuvalue=1`) | 56 | yes | back `luaC_barrierback` |

A literal closed `UpVal` *is* GC-traceable from a `CClosure` `TValue`
(`righttt`/`checkliveness` pass: `ttypetag==LUA_VUPVAL==gcvalue->tt`) and survives
**incremental** GC, but **crashes under generational GC** (`freeupval →
luaF_unlinkupval` in `youngcollection`'s sweep): Lua assumes every `UpVal` is
born *open* (on a thread's `openupval`/`twups` list) and closed only via
`luaF_closeupval`; a born-closed heap UpVal violates that contract. Rejected.

The `CClosure` cell and the `Udata` box both survive **every** mode. The
`CClosure` cell wins: it is **8 bytes smaller** than `Udata` (48 vs 56), drops the
unused metatable slot, and — the real simplifier — its mutation uses the **same
forward `luaC_barrier`** the codebase already emits for *every* closure-upvalue
store, so **one barrier rule covers both installing the box and mutating it**
(the `Udata` needs forward-install + back-mutate). The GC never calls a
`CClosure`'s `f` (it only marks `upvalue[]`; verified — no reached assertion
requires `f != NULL`), and the box is never callable from well-typed Titan. Its
`f` points at a **per-module trap stub** (resolved, D3b) —
`static int <prefix>box_trap(lua_State *L) { return luaL_error(L, "internal
error: Titan closure variable box called as a function"); }` — so a codegen bug
that ever made a box reachable as a callable fails loudly instead of jumping
through a NULL pointer. (Records keep their `Udata` box — they *do* flow into Lua
and need the metatable for method dispatch; the closure box is a deliberately
lighter, Lua-invisible representation.)

**Box lifecycle and barriers** (precise):

```c
/* create: a 1-upvalue CClosure used as a cell. luaF_newCclosure allocates. */
CClosure *_box_x = luaF_newCclosure(L, 1);
_box_x->f = <prefix>box_trap;                   /* trap stub; never legitimately called */
setnilvalue(&_box_x->upvalue[0]);               /* or init via setslot */
setclCvalue(L, s2v(_base + SLOT), _box_x);      /* anchor against GC */
```

- **Install** the box into the enclosing `CClosure`'s upvalue (closure
  construction): `setclCvalue(L, &cl->upvalue[i], box)` then
  **`luaC_barrier(L, cl, &cl->upvalue[i])`** — forward (closure container; matches
  `coderecord`, `coder.lua:1932`, and every closure-upvalue store).
- **Read** `x`:  `getslot(typ, dst, "&_box_x->upvalue[0]")`.
- **Write** `x`: `setslot(typ, "&_box_x->upvalue[0]", val)` followed by
  **`luaC_barrier(L, _box_x, &_box_x->upvalue[0])` iff `is_gc(typ)`** — forward
  again (the box is itself a closure). The store barrier is *load-bearing*:
  experiment E1 reproduced a deterministic use-after-free when an analogous box
  store omitted its barrier. (Non-gc types — integer/float/boolean/nil — need no
  barrier.)
- **Ordering discipline** (avoids an unanchored-box window — MAJOR from R1):
  1. evaluate the declaration's init expression first into a temp (it may
     allocate); 2. `luaF_newCclosure` the box, set `f=NULL`, and **immediately**
     `setclCvalue` it into its anchor slot with *no* allocation between (same
     adjacency as `coderecord` `coder.lua:1923-1932`); 3. `setslot` the init temp
     into `&box->upvalue[0]` (+ `luaC_barrier` if gc).
- The box is anchored in a dedicated stack slot (`newslot`) for the owning
  function's lifetime.

### 2.2 The `_fn` native-ABI parameter (validated: Appendix A/E3)

Every native entry gains `CClosure *_fn` **immediately after `_mod`** and
**before** the method `self`:

```c
RETTYPE f(lua_State *L, CClosure *_mod, CClosure *_fn, [self,] params…, outparams…);
```

`_fn` is the `CClosure` of the function value being invoked (its `upvalue[3..]`
are the captured variables). It is:

- `NULL` on the **static direct-call path** (`codecall`, point 2).
- `_vc_callee` on the **fast value-call path** (point 3).
- `clCvalue(s2v(func))` in the **Lua entry** (point 4) — note `_mod` is then
  `clCvalue(&_fn->upvalue[0])` (precise form; `coder.lua:2922` currently inlines
  this).

**Uniformity is mandatory.** The fast path dispatches purely on the function-type
*tag*, not on top-level-vs-anonymous, so all native entries of a given
`Type.Function` must share one ABI. Therefore *every* Titan function takes `_fn`,
even when it ignores it (top-level/static/method bodies simply never reference
it). Do **not** emit `(void)_fn;` to silence warnings: `driver.CFLAGS` is `-Wall`
(not `-Wextra`/`-Wunused-parameter`), so an unused parameter does not warn (R2).

### 2.3 Anonymous-function closure layout & creation (points 9–12)

An `ExpFunction` evaluates to a fresh `CClosure`:

```
upvalue[0]     = _mod                  (module closure — captured lexically)
upvalue[1]     = function-type tag     (light userdata)
upvalue[2]     = native entry ptr      (light userdata)
upvalue[3 + i] = captured variable i   (a CClosure-cell box, OR a copied value)
```

Built at the use site. **`lua_checkstack` first** (BLOCKER from R1 — the pushes
are *raw transient stack pushes*, not `newslot`-reserved):

```c
lua_checkstack(L, 3 + ncaptured);          /* ensure room for the pushes */
titan_pushmodule(L, _mod);
lua_pushlightuserdata(L, (void*)<functag>);
lua_pushlightuserdata(L, titan_cast_func(void*, <native_sym>));
/* one push per captured var, in node._captures order: */
setclCvalue(L, s2v(L->top.p), <box>);  L->top.p++;          /* boxed capture */
/*  …or…  */
<setslot of captured value into s2v(L->top.p)>; L->top.p++; /* by-value capture */
lua_pushcclosure(L, <lua_entry>, 3 + ncaptured);
/* result closure TValue is on top; consume into a gc temp (newtmp) and anchor */
```

`lua_pushcclosure` moves the pushed upvalues into the new (white) closure → no
barrier needed at creation. The closure *result* is a gc temp (`newtmp`, counted
in `nslots`); the transient capture pushes are **not** `nslots`-accounted (they
are popped by `lua_pushcclosure`). `_mod` is captured into `upvalue[0]` so the
lambda reaches module globals/imports/statics with the same `_mod->upvalue[...]`
code a top-level body uses.

---

## Part 3 — Checker: capture analysis (point 5)

For every in-function local/param `Decl`, compute:

- `decl._assigned` — assigned after declaration. **Exists** (`checker.lua:460`).
  The numeric-`for` control variable's implicit increment does *not* set it (it
  is codegen-internal and user-assignment is rejected, `checker.lua:455`), so a
  captured `for` variable stays immutable → by-value → fresh-per-iteration.
- `decl._captured` — **new**: referenced (read or write) from a function nested
  inside its declarer.
- `decl._used` — must be **forced true when a decl is captured** (MAJOR from R1):
  a variable only *written* (never read) by a nested function would otherwise
  miss `StatDecl`'s `_used` gate and never get its box allocated. Set
  `decl._used = true` in the capture hook.
- For each `ExpFunction`, `node._captures` — the ordered, de-duplicated list of
  enclosing-function decls it needs as upvalues (transitively), driving both the
  closure-creation pushes and the native body's upvalue indexing.

### Function-nesting tracking

The symtab (`symtab.lua`) is a flat block stack with no function boundary. Add
checker state, **explicitly initialised** `func_stack = {}` at the top of
`checker.check` (do *not* imitate `loop_depth`, which is module-global and never
reset — MINOR from R3):

- A stack `func_stack` of frames `{ depth, captures = {}, capture_set = {} }`.
- **Push the frame at the very top of `checkfunc`/`checkmethod`/the lambda
  checker — BEFORE declaring params/self** (MAJOR from R3: params/self must be
  stamped at the function's own depth), pop after the body.
- Stamp `decl._funcdepth = #func_stack` in the single `declare` helper
  (`checker.lua:221`) for locals, and in `checkfunc`/`checkmethod` for params/
  self (the minimal chokepoints — NIT from R4).
- **Capture detection in ONE place — the `VarName` visitor** (`checker.lua:535`),
  which uniformly covers reads (`ExpVar`, `ExpCall`, `VarDot` base) and assignment
  targets (`StatAssign` calls `checkvar` on its targets, `:419`). Keep
  `:460` solely for `_assigned`. When a resolved decl is a local/param
  (`decl._tag == "Ast.Decl"`, which excludes `TopLevelVar`/`TopLevelFunc`/module
  members — they resolve to non-`Decl` nodes; NIT/R3) and `decl._funcdepth <
  #func_stack`:
  - `decl._captured = true`; `decl._used = true`;
  - add `decl` to the `captures` list (first-seen order, deduped via
    `capture_set`) of **every frame in the inclusive range
    `[decl._funcdepth + 1 .. #func_stack]`** — i.e. every function from the one
    just inside the declarer up to **and including** the current (innermost)
    frame (BLOCKER from R3: the original "strictly between" wrongly omitted the
    innermost frame, so the deepest lambda would not capture the variable it
    actually uses).

This is a single in-order traversal; by the time `checkbodies` (`checker.lua:1403`)
finishes, all flags and capture lists are final, before codegen.

### `$function` nesting (return-type lookup)

`StatReturn` reads `st:find_symbol("$function")._type` (`checker.lua:478`). The
lambda checker must **itself open a dedicated block** (`st:with_block`) and
`add_symbol("$function", lambdaNode)` *into that opened block* before checking the
body, then close it — replicating the `checkbodies`+`checkfunc` pairing (BLOCKER
from R3: `checkfunc` adds `$function` to the *caller's* block, which works only
because `checkbodies` wraps it in `with_block`; a naive copy would leak
`$function` into the enclosing scope). The lambda node needs a `_type`
(`Type.Function` from its annotations) set before the body is checked.

### Shared body-check

Factor the body-check shared by `checkfunc` and the lambda checker: param/return
type checks, block check, and the all-paths-return rule (`checker.lua:1381` —
"function can return nil but return type is not nil" must apply to lambdas whose
first declared return type is non-`nil`).

### `ExpFunction` checker handler + type inference (D1+D6)

`['Ast.ExpFunction'] = function(node, st, errors, context)` — every `checkexp`
visitor already receives the 4th `context` arg (the expected type; e.g. `ExpCast`
uses it). The handler:

1. **Resolve parameter types.** Determine the expected function type: if `context`
   is a `Type.Function` whose arity matches `#node.params`, we are in *checking
   mode*; else *synthesis mode*. For each param: if it has an annotation, use it;
   else if checking mode, take `context.params[i]`; else (synthesis, no
   annotation) emit "cannot infer type of parameter 'x'". This mirrors `local x`
   vs `local x: T`.
2. **Resolve / set up return types.** If `node.rettypes` is an explicit list
   (incl. `{}` for `: ()`), use it. Else if checking mode, use `context.rettypes`.
   Else mark the frame for **return inference** (`frame.infer_ret = true`,
   `frame.collected = nil`).
3. Build `node._type = Type.Function(paramtypes, rettypes_or_placeholder, false)`.
   Push the frame (before declaring params — §"Function-nesting tracking"), open a
   block, bind params and `$function = node`, check the body.
4. **Return inference in `StatReturn`** (`checker.lua:478`): if the enclosing
   `$function`'s frame has `infer_ret`, *collect* each return's expression types
   (`tryforce`d, never option — as local inference does) instead of checking them
   against fixed rettypes; otherwise behave exactly as today (coerce/check against
   the known rettypes). After the body, unify the collected returns: zero returns
   → `{}` (zero-return); otherwise all returns must agree in arity and type (the
   first is the template; a mismatch → "cannot infer return type: returns disagree
   — add a return annotation"); set `node._type.rettypes` to the result.
5. Run the all-paths-return rule against the now-final rettypes (when inferring and
   there *are* returns but some path falls through, the existing "can return nil
   but return type is not nil" error fires — prompting an annotation). Pop frame.
6. Return with `_type = node._type`. The surrounding context then applies the
   usual `trycoerce`/`checkmatch` of the lambda *value* against its target (in
   checking mode this matches by construction; in synthesis mode the synthesized
   type is validated like any other expression).

### Bound method references (point 4 / §4.6)

A method named but **not called** is a bound-method value. Surface syntax
(proposed, D7): `obj:method` with no argument list — `r:m` parses to a new
`Ast.VarDotColon`/method-ref node (today `r:m` *requires* a call, so this is
additive). Its type rule: a receiver of nominal/record type with method `m :
Type.Method(fqtn, name, params, rettypes)` yields a value of
`Type.Function(params, rettypes, false)` — i.e. the method type with the implicit
`self` removed. The receiver expression is evaluated once (eagerly) when the bound
value is created. Checking reuses method resolution (`checker.lua` VarDot/method
paths); codegen is §4.6. (FFI/foreign methods and static methods are unaffected —
`Rec.new` already works as a value.)

---

## Part 4 — Coder

### 4.1 `_fn` threading (points 1–4)

- `function_sig` (`coder.lua:562`): insert `"CClosure *_fn"` after
  `"CClosure *_mod"` and **before** the method `self` insertion (`:564`), for all
  function types. This automatically updates the fast-path typedef
  (`codevaluecall` uses `function_sig(fptype, ftype, true)`, `:1385`) and the
  cross-module externs (`coder.lua:3247/3260`).
- `codefuncdec` (`coder.lua:2960`): add `"CClosure *_fn"` to `cparams` after
  `_mod`, before the method self — **identical order to `function_sig`** (make
  this an explicit invariant; R2).
- `genluaentry` (`coder.lua:2840`): add `"_fn"` to `pnames` after `"_mod"`; emit
  `CClosure *_fn = clCvalue(s2v(func));` and keep `_mod =
  clCvalue(&_fn->upvalue[0]);` (refactor of `:2922`).
- `codecall` static path: insert `"NULL"` into `caexps` immediately after each
  `modarg` and **before** the method `self` arg, so every direct call is
  `(L, _mod, NULL, [self,] args…)` (`coder.lua:1458/1481/1482`; MINOR/R1).
- `codevaluecall` fast path (`coder.lua:1330`): change `fastargs` from
  `{ "L", "_vc_mod" }` to `{ "L", "_vc_mod", "_vc_callee" }`. Slow path
  unaffected (goes through the Lua entry, which supplies `_fn`).
- **Checklist** of every call/decl site to re-verify after this edit (from R2's
  enumeration): calls — `coder.lua:1333, 1512, 2873, 2883`; decls/typedefs —
  `562, 1385, 3036, 3247, 3260`; closure builds — `3598/3614/3629/3651`.

### 4.2 Boxed-variable codegen in the **owning** function (points 6–8)

Gate on `decl._boxed := decl._captured and decl._assigned`. Storage becomes a
`CClosure*` box (`decl._box`) instead of a plain C local:

- **`StatDecl`** (`coder.lua:1601`): allocate per §2.1 ordering; box gated on
  `decl._boxed` (not on `_used` alone — the capture analysis forces `_used` true,
  but gate the *box* on `_boxed`). Set `decl._box`, `decl._boxed = true`.
- **Params** (`codefuncdec`, `coder.lua:2969`): a boxed gc-typed param is first
  anchored in its existing `_paramslot`, **then** the box is allocated, **then**
  the incoming `_param_x` is copied into `&box->upvalue[0]` (ordering avoids an
  unanchored window — MINOR/R5).
- **`for` control variable**: never boxed (immutable). The "never boxed"
  invariant relies on codegen running only after zero type errors (true: `titanc`
  typechecks all modules and exits before codegen); optionally guard `:460` with
  `if not var._decl._forcontrol` defensively.
- **Reads** (`codevar` else-branch, `coder.lua:1739`): if `node._decl._boxed`,
  return `getslot(node._type, nil, "&"..decl._box.."->upvalue[0]")`.
- **Writes** (`codeassignment` local-var branch, `coder.lua:1019`): if
  `var._decl._boxed`, `setslot(typ, "&"..box.."->upvalue[0]", cexp)` +
  `luaC_barrier(L, box, &box->upvalue[0])` when `is_gc(typ)`.
- Non-boxed locals/params keep today's representation verbatim (point 8).

### 4.3 Anonymous-function emission (points 9, 12)

`codeexp` gains an `Ast.ExpFunction` arm. Native + Lua entries live at **file
scope**, so lambda bodies are collected during body codegen and emitted with the
top-level functions:

- Each `ExpFunction` gets a unique name `<modprefix>lambda_<N>` (counter on
  `tlcontext`, like `functag_count`); unique across nested lambdas.
- `codelambdadec(tlcontext, node)` mirrors `codefuncdec` but the signature is
  `(L, _mod, _fn, params…, outparams…)`, the body reads captures from `_fn`
  (§4.4), and it produces `_body`/`_sig`/`_luabody` (`genluaentry` works once it
  accounts for `_fn`).
- `codeexp(ExpFunction)` appends the lambda to `tlcontext.lambdas` and returns the
  closure-creation C (§2.3) as prelude + the closure `TValue` as value. Captures
  are pushed in `node._captures` order: a **boxed** capture pushes the box
  (`setclCvalue` of `decl._box`, or — when the capture is transitive — the box
  read from the *current* function's `_fn`, §4.4); a **by-value** capture pushes
  the value via `setslot`.
- **Emission loop** (D4 resolved): after the main toplevel loop in
  `coder.generate`, drain `tlcontext.lambdas` with an **index-based `while` loop
  that re-reads `#tlcontext.lambdas` each iteration** — a lambda nested inside a
  lambda is discovered only while emitting the outer one, so `ipairs` over a
  snapshot would miss it (MINOR from R5).

### 4.4 Captured-variable access in the **lambda** body (points 10, 11)

The lambda body context gets a map `ctx.captures` (decl → upvalue index),
consulted in `codevar`/`codeassignment` **before** the `decl._cvar`/`decl._boxed`
logic (the outer C locals are not in scope inside the lambda). For each captured
decl `c` at upvalue index `3 + i`:

- **Boxed** (`c._boxed`): the upvalue holds the shared box. Bind once at entry
  `CClosure *_box_c = clCvalue(&_fn->upvalue[3+i]);`, then read via
  `getslot(c._type, …, "&_box_c->upvalue[0]")` and write via `setslot` +
  `luaC_barrier(L, _box_c, &_box_c->upvalue[0])` (gc). Point 10 — the box
  *pointer* was copied; all sharers mutate one boxed value.
- **By-value** (`not c._boxed`): the upvalue holds the copied value; read directly
  with `getslot(c._type, …, "&_fn->upvalue[3+i]")`. Immutable in the lambda
  (by construction). Point 11.

**Transitive capture** (C in B in A; C uses A's var): the analysis (§3) put the
var in both B's and C's `_captures`. When B builds C's closure, B reaches the
var only via *its own* `_fn` (B captured it from A), so B's closure-build reads
the box/value from `B`'s `_fn->upvalue[j]` and pushes it into C's closure. The
per-frame `captures` lists + decl→index maps make this fall out. Boxed transitive
captures share the one box (pointer copied down the chain); by-value transitive
captures copy the immutable value down.

### 4.5 Stack discipline

The closure *result* and any boxes go through `newslot`/`newtmp`, counted in
`ctx.nslots`; the function preamble reserves them (`coder.lua:2988`). The
**capture pushes are transient** — guarded by `lua_checkstack(L, 3 + ncaptured)`
(§2.3), consumed by `lua_pushcclosure`, **not** `nslots`-accounted. A lambda that
performs value-calls sets `ctx.uses_base_off`. `lua_checkstack` can reallocate
the stack, so recompute `_base` from a `savestack` offset afterward where the
existing value-call code already does (`luaF_newCclosure`/`lua_pushcclosure`
themselves do not relocate the stack — correct the rationale; MINOR/R1).

### 4.6 Bound method closures (point 4)

A bound-method value `obj:m` is a closure capturing the receiver as its single
"upvalue capture", with two tiny **trampoline** entry points that delegate to the
method's existing native/Lua entries. Per the user's design.

**Closure layout** (same shape as a 1-capture lambda; the capture *is* `self`):

```
upvalue[0] = _mod                         (the defining module's closure)
upvalue[1] = function-type tag            for (params) -> rettypes  (self removed)
upvalue[2] = bound trampoline native ptr  (NOT the method's own native entry)
upvalue[3] = self                          (the receiver, a CClosure* for records)
```

**Two trampolines, emitted by the method's defining module for *every* method**
(so a bind site in another module — which only has the `.so` — can point at them;
they are small, just delegations):

- **Native trampoline** — matches the bound function type's ABI
  `RETTYPE m_bound(L, _mod, _fn, params…, outparams…)`; it extracts
  `self = clCvalue(&_fn->upvalue[3])` (the captured receiver) and tail-calls the
  real method native entry `m_native(L, _mod, NULL, self, params…, outparams…)`
  (the method's own `_fn` is `NULL` — its captures, if any, are a separate
  concern). This is exactly a hand-written one-capture lambda whose body is "call
  the method with the captured self."
- **Lua trampoline** — a `lua_CFunction`; it inserts `self` (from its closure's
  `upvalue[3]`) as the first stack argument and delegates to the method's existing
  **Lua** entry, so the boundary checks/coercions are reused unchanged.

**Codegen.** Extend `codefuncdec`'s method arm (or a new `codemethodtrampoline`)
to also emit `m_bound` (native) and `m_bound_lua` (Lua), with exported/recoverable
symbols mirroring the method's own entries (and a `function_type_tag` for the
self-removed type). At a bind site `obj:m`: evaluate `obj` once into an anchored
temp; `lua_checkstack(L, 4)`; push `_mod` (the *method's* module — its closure is
already an upvalue of the binder's `_mod` for cross-module methods, exactly as
method *calls* recover it, `coder.lua:1463-1478`), the tag, the bound native
trampoline pointer, and `self`; `lua_pushcclosure(L, m_bound_lua, 4)`. The result
is an ordinary `Type.Function` value — callable via both paths, storable, Lua-
crossable — with no special handling downstream.

**Cross-module / `.so`.** Because the trampolines are emitted per method by the
defining module and reached by the same cross-module symbol machinery as method
native entries (`ctx.functions`, the `function_sig` externs at
`coder.lua:3247/3260`), a bound reference created in an importer works against a
`.so`-only dependency. (This rides on the same `_fn` ABI / `TITAN_VER` bump as the
rest — §7.5.) Add a `so_import`-style test for a cross-module bound method.

**Why per-method, always.** A method may be bound in a module that imports the
defining one only as a compiled `.so`; the trampolines must therefore exist as
real exported symbols of the defining module, not be synthesised at the bind site.
They are cheap (pure delegation), so emitting them for every method is fine.

---

## Part 5 — Documentation

- `doc/language/index.md:79` — move anonymous functions, closures-over-locals,
  **and bound instance methods** out of the "not first-class" list (only FFI
  functions remain non-first-class).
- New closures section (in `functions.md` or `closures.md`): lambda syntax with
  **optional annotations + inference** (params from context, return from body —
  framed as the same inference as `local x`); lexical capture (presented simply as
  "closures capture enclosing locals"); no-stable-identity + equality meaning; the
  D2 recursion limitation (clean "not declared" error). Document **bound method
  references** `obj:m` (in `records.md`/`functions.md`).
- `doc/implementation/codegen-overview.md:173` — document `_fn` in the ABI shape;
  add a closures subsection (CClosure-cell box, barrier rules, capture lists, transitive
  capture, the `3 + N` upvalue layout, the `.so` ABI bump).
- `doc/implementation/checker.md` — capture analysis (flags, `func_stack`,
  `_funcdepth`, the inclusive capture interval).
- Reconcile `doc/first-class-functions-spec-v1.md` scope note (it excluded
  nested/anonymous; point that this now exists). Dated `documentation-worklog.md`
  entry if that convention is live.

---

## Part 6 — Testing plan

Conventions per CLAUDE.md: pure/parser at `spec/` root; checker-only under
`spec/checker/`; end-to-end under `spec/coder/`; reset
`types.registry`/`driver.imported` in helpers.

**parser_spec.lua**: lambda parses (no/with return annotation, zero/multi param,
nested, in arg/init-list/record-field position); parenthesized application
`(function…end)(x)`; direct application `function…end(x)` is a parse/checker
error; malformed-lambda error labels; a 3–4 deep nesting case (parser limit).

**spec/checker/closures_spec.lua** (new): capture flags (captured-mutated,
captured-immutable, mutated-not-captured, neither, shadowing, **transitive
3-level**, for-var capture, self capture); type errors through a lambda value;
**top-level `local x = function…end` → "must be constant"** (R4 BLOCKER
regression); D2 self-reference → "not declared". **Inference (D1/D6):**
param inferred from an assignment-target/argument/return function type; return
inferred from the body (single and multi-return; unify); unannotated param with
no context → clean error; conflicting returns → clean error; explicit `: ()` is
zero-return (distinct from no annotation). **Bound methods (§4.6):** `obj:m` has
type `(params)->rettypes` (self removed); using it where a function value is
expected typechecks; FFI/foreign method ref rejected.

**spec/coder/closures_spec.lua** (new), end-to-end (generate C, compile, run):

- **Counter** (canonical): `make_counter()` returns a lambda incrementing a
  captured boxed integer; two counters independent; repeated calls accumulate.
- **By-value capture**: lambda reads an immutable captured local; loop-created
  closures each capture the per-iteration value (fresh-per-iteration).
- **Both call paths** (fast: exact-type; slow: stored as `value` then called).
- **gc-typed captures** (string/array/record) — exercises the box `luaC_barrier`.
- **Transitive 3-level** (shared boxed mutation + by-value across two levels).
- **Lambda ⇄ Lua boundary** both ways; a passed-in Lua closure stored/called.
- **`_fn` ABI regression**: existing first-class top-level value call still works.
- **GC stress**: build closures + boxes, hard `collectgarbage()` between creation
  and call, assert no corruption (box anchor + barriers — highest value).
- **Zero-return lambda** invoked for effect; `(f())` adjust (D1).
- **Feature interactions** (R5): lambda-returns-lambda (escape two frames);
  lambda in a record field then GC then call; IIFE via parens; lambda passed
  across an import and stored/called.
- **Inference end-to-end**: a lambda with inferred params (from an argument
  position, e.g. a higher-order `apply`) and an inferred body return, compiled and
  run; confirms the inferred type drives codegen correctly.
- **Bound methods (§4.6)**: `obj:m` stored and called (fast + slow path); a bound
  method that mutates record state via `self`; a bound method handed to Lua and
  called; a **cross-module / `.so`-only** bound method (so_import-style) — verifies
  the per-method trampolines are reachable across the boundary; GC stress on a
  stored bound method (self stays anchored via the closure upvalue).

**Audit**: no existing fixture uses `function` as an expression, so the parser
change is additive — but adding `_fn` to **every** native signature changes all
generated C, so the full `spec/coder/` suite is the regression oracle for the ABI
step. Run it first after §4.1, before any closure feature.

---

## Part 7 — Risks & implementation guardrails

1. **GC barriers/anchoring** (highest): with the `CClosure`-cell box, *both* box
   install into the enclosing closure *and* box mutation use forward
   `luaC_barrier` (one uniform rule); the `lua_checkstack(3 + ncaptured)` before
   capture pushes; the create-then-anchor-then-store ordering; boxed-param
   anchor-first ordering. E1 proved the store barrier is a deterministic UAF if
   omitted.
2. **ABI uniformity**: `_fn` after `_mod`, before `self`, in *both* `function_sig`
   and `codefuncdec`; every call site updated (the §4.1 checklist). The fast-path
   typedef and cross-module externs track automatically via `function_sig`.
3. **Capture analysis**: inclusive transitive interval; `$function` via a
   dedicated block; frame pushed before params; single VarName hook; `_used`
   forced on capture.
4. **Lambda emission**: file-scope hoisting via the re-reading `while` loop;
   unique naming; capture-list/upvalue-index agreement between the parent's
   closure-build and the lambda's capture-read.
5. **`.so` ABI break (promoted to a hard requirement).** Adding `_fn` to
   `function_sig` changes every native-entry signature, including the cross-`.so`
   value fast path (`spec/coder/so_import_spec.lua:183`) and cross-module externs
   (`coder.lua:3247/3260`). Old and new compiled `.so`s are **ABI-incompatible**;
   mixing them is undefined behavior. **Bump `TITAN_VER` 0.5 → 0.6**
   (`titan-runtime/titan.h:16-20` — changes the search path and version suffix)
   and document that all dependency `.so`s must be recompiled. This is mandatory,
   not "verify."
6. **Inference soundness** (D1/D6): checking-vs-synthesis mode selection; the
   return-collection mode in `StatReturn` must not double-coerce; unannotated
   param / conflicting-return errors must be clean; inferred type must be final
   before the closure-creation codegen reads it. Cover with checker specs.
7. **Method trampolines** (§4.6): the bound native trampoline's ABI must match the
   self-removed function type exactly; the per-method trampolines must be emitted
   and exported for *every* method (cross-`.so` bind sites depend on them); `self`
   stays anchored via the closure upvalue. Cover with a cross-module bound-method
   test.

---

## Part 8 — Open decisions (for the user)

- **D1 — Return-type inference for lambdas. RESOLVED → infer** (user). No
  annotation → take the context's return types if the lambda flows into a known
  function type, else infer from the body's `return`s (unified). Explicit `: ()`
  still means zero-return. Algorithm in §3. Parallels `local x = exp` inference,
  so it is consistent with explicit typing, not a departure.
- **D2 — Nested `local function` & direct recursion.** *Recommend:* out of scope
  for v1 (anonymous expressions only); self-reference is a clean "not declared"
  error; document the workaround. Could be a fast follow (desugar `local function
  f` → `local f; f = function…`).
- **D3 — Box representation. RESOLVED → 1-upvalue `CClosure` cell** (trap-stub
  `f`, D3b; empirically; §2.1, Appendix A). 48 bytes, survives every GC mode, barrier-
  uniform (forward `luaC_barrier` for both install and mutate), no Lua-facing
  baggage since the box never escapes to Lua. Literal `UpVal` rejected (crashes
  generational GC); `Udata` box workable but 8 bytes larger with an unused
  metatable slot and a mixed barrier rule.
- **D3b — box `f`: NULL vs trap stub. RESOLVED → trap stub** (user). A per-module
  `<prefix>box_trap` that `luaL_error`s; a codegen bug that ever calls a box fails
  loudly rather than via a NULL jump (§2.1).
- **D4 — Lambda collection. RESOLVED → lazy**, drained with a re-reading `while`
  loop (§4.3).
- **D5 — Direct application `function…end(args)`. RESOLVED → unsupported**;
  require `(function…end)(args)` (lambda is a `simpleexp`, not a `prefixexp`).
- **D6 — Lambda parameter type inference from the expected type. RESOLVED →
  infer** (user). Unannotated params take their types from the expected function
  type (`context`); with no context, an unannotated param is a clean error.
  Threads through the existing `context` arg. Algorithm in §3.
- **D7 — Bound-method-reference surface syntax. PROPOSED → `obj:method`** (bare,
  no call). Additive (today `r:m` requires a call). Open to a different spelling
  if you prefer; the runtime mechanism (§4.6) is independent of the syntax choice.

---

## Part 9 — Implementation workflow structure

Same constraints as first-class functions: shared singleton build env; compile/
test **serialize** in the main tree; only source edits and standalone uniquely-
named C probes parallelize (CLAUDE.md: *Titan build parallelism*; *dual luarocks
tree* — re-run both `luarocks make` and `luarocks make --local` after compiler
edits).

1. **ABI step (§4.1) + `.so` version bump (§7.5)** — *sequential.* Add `_fn`
   everywhere; feature inert but every signature changes. **Full existing suite
   green** is the regression gate.
2. **Frontend (§1, §3)** — *sequential.* Parser `ExpFunction` (with optional
   param annotations + `lambdarettypeopt`) + AST node + `isconst` arm; checker
   capture analysis, lambda body check, **and inference** (param + return, D1/D6).
   Verify parser + checker specs.
3. **Coder boxes (§4.2) + trap stub** — *sequential.* Boxed-variable
   representation; verify a top-level function that boxes a local (no lambda yet —
   a valid isolated config) still round-trips.
4. **Coder lambdas (§4.3, §4.4)** — *sequential, largest step.* Emission, closure
   creation, captured access, transitive capture. Verify each end-to-end case.
5. **Bound method closures (§4.6)** — *sequential.* Per-method trampolines, bind-
   site codegen, cross-module/`.so`. Reuses the closure machinery from steps 3–4.
6. **Tests + docs** — test authoring + docs fan out via worktrees (write-only);
   then serial `busted` in the main tree.
7. **Multi-agent PR review (user request)** — after tests + code are green, run a
   dynamic review workflow: several reviewer agents over the actual diff, each on a
   dimension (GC barriers/anchoring; ABI & upvalue-index agreement; capture
   analysis & inference soundness; method-trampoline correctness incl. cross-`.so`;
   parser/AST/types; test coverage & completeness), with adversarial verification
   of each finding before it is reported. Fix, then re-run `busted`.

Dedicated **adversarial verification** agents (read-only, parallel) also run after
step 4 for GC barriers/anchoring and ABI/upvalue-index agreement (folded into the
step-7 review for the final pass).

---

## Appendix A — Experiment results (standalone C vs the real Lua 5.5 tree)

All four confirmed the design on Lua 5.5 internals; sources under `/tmp`
(`titan_upval_probe.c`, `titan_box_compare.c`, plus the workflow's
`titan_exp_e1..e4`). Run against `lua-5.5.0/src/liblua.a` and an assertions build
(all Lua `.c` compiled `-DLUAI_ASSERT`, so a full GC exercises `checkliveness`).

- **E1 — Udata box GC-soundness + load-bearing barrier: CONFIRMED.** Boxed GC
  values (string, table) survive full GC + heavy churn while reachable via the
  anchored closure. A deterministic use-after-free was reproduced by omitting the
  store barrier (blacken box → store fresh white value → sweep → freed slab
  handed back, payload clobbered). With `luaC_barrierback`/`luaC_barrier`: intact.
- **E2 — literal closed UpVal in a CClosure TValue: VIABLE under incremental,
  passes `checkliveness`** (asserts build, with a negative control proving asserts
  active) — **but superseded by the head-to-head below.**
- **Head-to-head under GENERATIONAL GC** (`titan_box_compare.c` /
  `titan_box_ccl.c`, asserts builds): the `Udata` box and the **`CClosure`-cell
  box (NULL f in the probe; the design uses a trap-stub f — irrelevant to GC)**
  both **SURVIVE** 150 rebox rounds with stable identity; the
  literal `UpVal` **SEGFAULTs** (`freeupval → luaF_unlinkupval` in
  `youngcollection`'s `sweepgen`). Sizes: `UpVal`=40, `sizeCclosure(1)`=48,
  `Udata(1uv)`=56. The `CClosure` cell's mutation uses the same forward
  `luaC_barrier` as its install (verified `righttt`/`checkliveness` and NULL-`f`
  GC-safety in the asserts build). → **D3 resolved in favor of the `CClosure`
  cell** (smallest GC-safe option, barrier-uniform, no Lua-facing baggage).
- **E3 — uniform `_fn` ABI: CONFIRMED.** One convention covers `_fn`-ignoring
  (top-level) and `_fn`-reading (closure) entries; calling through a
  `function_sig`-style function pointer pulled from a light-userdata upvalue gives
  identical results to direct calls; capture survives GC.
- **E4 — end-to-end counter: CONFIRMED.** Captured-and-mutated local boxed as a
  1-uv Udata in a CClosure upvalue, called via the fast path, gives correct
  per-closure independent state, accumulation, and GC survival — no new GC
  machinery beyond the barrier `coderecord` already uses.

## Appendix B — Adversarial review findings (folded into the plan above)

5 reviewers. Blocker/major items, all addressed: closure-creation needs
`lua_checkstack` before pushes (R1); capture pushes are transient, not
`nslots`-accounted (R1); box mutation barrier (R1 found the `Udata` option needs
`luaC_barrierback` vs `lua_setiuservalue`; the final `CClosure`-cell box instead
uses the uniform forward `luaC_barrier`); `StatDecl` box must fire on `_boxed` and capture must force
`_used` (R1); create-then-anchor-then-store ordering (R1); **transitive capture
interval must be inclusive of the innermost frame** (R3); `$function` needs its
own `with_block` in the lambda checker (R3); push the frame before declaring
params/self (R3); **top-level `local x = function…end` must be rejected via
`isconst`** else the checker/codegen crashes (R4); **`_fn` is a hard cross-`.so`
ABI break → bump `TITAN_VER`** (R2, R5); function-value equality is raw pointer
compare → define/document for lambdas (R5); lazy lambda emission must re-read
`#lambdas` for nested lambdas (R5). ABI uniformity dimension reviewed **SOUND**
with a complete call-site checklist (R2, in §4.1). Minor/nit items (parser
nesting bound, `(void)_fn` unnecessary under `-Wall`, D1/D2 wording, `_funcdepth`
stamping in `declare`, extra test interactions) also folded in.
