# First-Class Functions for Titan — Spec, Improvements & Implementation Plan

## Context

Titan currently forbids using a function as a value: a function name can only be
*called*, function-type annotations (`(integer) -> integer`) are a clean compile
error, and there is no way to call a Lua function from Titan. First-class
functions are the headline item on the roadmap (`doc/language/philosophy.md`,
`doc/language/index.md`). The user drafted a v1 design in
`doc/first-class-functions-spec-v1.md`. This plan evaluates that draft against
Titan's philosophy, folds in the improvements and decisions the user confirmed,
and lays out a full spec + implementation + testing plan structured for execution
by a follow-up multi-agent dynamic workflow.

**Confirmed decisions (this session):**
1. **Two call paths** for invoking a function value (simplification from the draft).
2. **Stable object identity** — one canonical function value per function, held in
   a *shadow module variable* (a `_mod` upvalue slot), reused everywhere.
3. **Zero-return `()` functions are the default** — a function with **no return
   annotation** is now a real zero-return `()` function (distinct from `nil`).
   This brings Titan in line with Lua, where an unannotated `function f() end`
   returns *nothing* (`select('#', f())` is `0`), not one `nil`. Native entry
   returns C `void`; `return` (bare) is the only return — `return nil` becomes an
   arity error; `: nil` is the explicit one-`nil`-return annotation; a
   `()`-returning call is a compile error in expression context except `(f())`,
   which adjusts up to a single `nil`. The user authorized this breaking change
   (no production Titan code); existing specs/fixtures will be audited and updated.

**Intended outcome:** Titan top-level functions and record statics become
first-class values that can be stored, passed, returned, and called through;
Lua/C/`__call` values can be received and called; exact-typed Titan calls keep
the zero-overhead native path; everything is GC-safe and crosses the Lua boundary
faithfully.

---

## Part 1 — Evaluation of the v1 draft & improvements adopted

The draft is well-aligned with Titan's philosophy ("performance from
specialization", "Lua GC is the only GC", "safety at the boundary"). The type
machinery (`types.equals`/`compatible`/`tostring`/`serialize`/`is_gc` over
`Type.Function`) is already complete and correct (`titan-compiler/types.lua`),
and `types.coerceable` deliberately has no Function case — so function values are
never silently coerced, only checked. Reusing the existing per-function
`CClosure` and the record-style tag registry is economical and consistent.

Improvements adopted over the literal draft (each verified against the code):

- **Keep `_mod` at upvalue[0]; add tag at [1], native pointer at [2].** The draft
  proposed moving the module reference to slot 2. That is unnecessary and
  invasive: `genluaentry` reads `_mod` from `clCvalue(s2v(func))->upvalue[0]`
  (`coder.lua:2692`) and the install code (`coder.lua:3306-3331`) depends on it.
  A *fixed* slot 1 is just as "offset-free" as slot 0 for the tag check, so
  keeping `_mod` at 0 means **zero edits** to the entry/install/call paths. Only
  the upvalue count grows (1 → 3) and two `lua_pushlightuserdata` calls precede
  `lua_pushcclosure`.
- **Slot type is a boxed `TValue`, not `CClosure*`.** A function value may be a
  Lua closure, a light C function, or a `__call` object — not only a Titan
  `CClosure`. So `ctype(Type.Function) = TValue` (like `value`/`option`), and the
  fast-path `CClosure` shape is recognized at runtime, not assumed in the C type.
  This matches the draft's "always boxed Lua TValues".
- **Function-type tags use *publish-or-recover*, not the record split.** A record
  tag has exactly one declaring module that publishes it; a *function type* like
  `(integer) -> integer` has no single owner — several unrelated modules may use
  it. Each module must therefore run "publish if absent, else recover" for every
  function type it needs, and this must happen **before** the per-function
  closures are built (see Part 3). The registry **key** is the canonical type
  string verbatim; the C identifier for the `static const void*` is numbered
  per-module (like `ctx.metatables`, `coder.lua:167-172`) to avoid fragile
  string→identifier mangling.
- **Identity via a shadow module variable.** Each referenced function gets one
  canonical value built once at `_init` into a dedicated `_mod` upvalue slot;
  internal references and the exported module-table entry all point at that same
  object, so `m.f == m.f` and `get() == m.f` hold from Lua.
- **Foreign-function rejection is not free.** Foreign members are valid
  `Type.Function`-typed `Type.ModuleMember`s; relaxing `ExpVar` on `Type.Function`
  would *accidentally* allow them. The rejection must key on the receiver being
  `Type.ForeignModule` (`checker.lua:538`).
- **No boundary callability check — defer to the call.** A function-typed value
  arriving at the boundary (a parameter from Lua, or a `value` → function cast) is
  stored as a boxed `TValue` with no `ttisfunction`/`__call` test; `luaD_callnoyield`
  raises cleanly if it turns out not to be callable when actually invoked. So
  `checkandget` and the `value` → function cast for `Type.Function` mirror
  `Type.Value` exactly, and `__call` objects, C functions, and Lua closures all
  work for free.

---

## Part 2 — Full language spec (v1.1)

### Scope

A **function value** is one of:
- a reference to a Titan top-level function (`local` or exported),
- a reference to a record static function (only `Record.new` exists today), or
- a Lua function-like value (plain Lua function, C function, or `__call` object)
  arriving via a function-typed parameter or a `value` cast.

Out of scope (remain compile errors / unsupported): anonymous & nested
functions, closures over locals, **instance methods** as values (they need a
bound `self`), and **FFI/foreign functions** as values.

### Function types

Written `(P1, …, Pn) -> R` for a single return, `(P…) -> (R1, …, Rm)` for
multiple, `() -> R` for no params, and **`(P…) -> ()` for zero return values**.
`->` is right-associative; higher-order types nest:
`(integer -> integer, integer) -> integer`. A function with **no return
annotation** is now a **zero-return `()` function** (see below) — changed from the
old `nil`-returning default. `: nil` is the explicit one-`nil`-return annotation.

### Zero-return `()` functions

- **The no-annotation default is `()`.** `function f(...)` with no `: type` has
  type `(...) -> ()` and returns **zero** values — matching Lua, and *replacing*
  the old "unannotated returns one `nil`" rule. A function declared `function
  f(...): ()` (or a value typed `… -> ()`) is the same thing written explicitly.
  Its native entry returns C `void`. **At the Lua boundary it now returns zero
  values** (not one `nil`), so `select('#', m.f())` is `0` — a deliberate,
  Lua-faithful behavior change.
- In such a function `return` (no expression) is the only legal return; `return nil`
  or `return expr` is an arity error (`returned 1 value(s) but function expected 0`).
  Falling off the end is allowed. The old equivalence `return` ≡ `return nil` no
  longer holds — they now differ (the whole point of doing `()` properly).
- A one-`nil`-returning function is written explicitly with `: nil`.
- A call to a `()`-returning function is valid as a **statement** but is a
  **compile error in expression context** (`a function returning no values cannot
  be used as a value` or similar), **except** when explicitly adjusted with
  parentheses: `(f())` produces a single `nil` value (Lua-style up-adjustment).
- `() ` is canonicalized in `types.tostring` as `(P…) -> ()` and is a distinct
  type from `(P…) -> nil` (different tag, no fast-path match between them).

### Referencing, storing, passing, returning

A function name (or `Record.new`) used as a value yields its canonical function
value. Function values may be assigned to function-typed locals/params/fields,
passed as arguments, returned, and stored in arrays (`{(integer)->integer}`),
maps, and record fields.

### Calling a function value — two paths (semantics)

Calling `f(args)` through a function-typed value of static type
`T = (P…) -> (R…)`:
1. **Exact Titan match (fast):** if the value is a Titan function whose exact type
   is `T`, call its native entry directly with unboxed args — zero Lua-stack
   round-trip, after one constant-time tag check.
2. **Lua value (generic):** call generically through the Lua stack using `luaD_callnoyield`.
   There is no need to check the tag, since `luaD_callnoyield` will do that and raise and
   error if value is not callable.

Both are sound: the fast path runs only on an exact type match (no checks
needed); the slow path applies full dynamic checking at the boundary and on results.

### Gradual typing & casts

`value` ↔ function conversions follow the standard rule: function → `value` is
free and implicit; `value` → function also succeeds implicitly, the check is deferred
until the function value actually gets called. A function value stored as `value`
round-trips back to a callable function type.

### Lua interoperability

- A Titan function with a function-typed parameter can be **passed and call a Lua
  closure / C function / `__call` object** — this is the first time Titan can call
  Lua code directly (update `doc/language/lua-interop.md`).
- A Titan function value handed out to Lua is an ordinary callable from Lua.
- **Identity:** `f == g` from Lua holds when both denote the same underlying
  function (stable identity via the shadow module variable).

### What stays a compile error

Instance method as a value; foreign function as a value; the record type itself
or a module alias as a value (unchanged); calling a non-function value; using a
`()`-returning call where a value is required (except `(f())`); `return nil` (or
any value) inside a `()`/unannotated function (arity error).

---

## Part 3 — Value representation & runtime design

### Function value object

A Titan function value is a `CClosure` whose `f` is the existing Lua entry
wrapper (`func_luaname`/`static_luaname`), with upvalues:

```
upvalue[0] = module _mod        (CClosure*, UNCHANGED — keeps existing reads valid)
upvalue[1] = function-type tag  (light userdata: address of a per-type static)
upvalue[2] = native entry ptr   (light userdata: the RETTYPE f(L,_mod,…) symbol)
```

Built via: `titan_pushmodule(L, _mod)`, `lua_pushlightuserdata(L, <functag>)`, 
`lua_pushlightuserdata(L,titan_cast_func(void*, <native_sym>))`,
`lua_pushcclosure(L, $LUANAME, 3)`. `lua_pushcclosure` needs no extra
`luaC_barrier` (the new closure is white; verified in `lua-5.5.0/src/lapi.c`).

### Shadow module variable (identity)

Every **referenced** function gets one dedicated `_mod` upvalue slot allocated
in `allocate_upvalues` (`coder.lua:3213`), gated on a checker flag (e.g.
`node._valref`) set in pass 2 when a function is used as a value. **Exported
functions and statics always get one** (an unseen importer may take their value);
**local functions only if referenced as a value in-module.** At `_init` the
canonical closure is built once into that slot; exported functions then install
*that same object* into the module table (rewrite of `coder.lua:3306-3331` from
"build fresh each install" to "build once into the slot, copy the slot into the
table"). A reference to the function as a value reads the slot directly (O(1), no
hash lookup), boxed as a `TValue`.

### Type tags — publish-or-recover, with correct `_init` ordering

Per distinct function type the module needs a tag for (any exact-match call
target, or the exact type of any referenced function), emit
`static const void *<modprefix>functag_<N>;` with a compile-time map
canonical-string → N (mirrors `ctx.metatables`). In `_init`, **before** the
per-function closures are built (i.e. in the `$INITRECORDS` region, ahead of the
`upvalue[0]` table creation at `coder.lua:2913`), run for each:

```c
lua_getfield(L, LUA_REGISTRYINDEX, "Titan function type (integer) -> integer tag");
if (lua_isnil(L,-1)) {                 /* first to use this type wins */
  lua_pop(L,1);
  functag_N = &functag_N;
  lua_pushlightuserdata(L, functag_N);
  lua_setfield(L, LUA_REGISTRYINDEX, "Titan function type (integer) -> integer tag");
} else {
  functag_N = lua_topointer(L,-1);
  lua_pop(L,1);
}
```

This recovery must also run in the `_init` "already loaded but not initialized"
branch (`coder.lua:2921-2929`, the `$INITTAGS` phase), because the
`static const void*` is per-shared-library global state. The registry **key** is
the verbatim canonical string; only the C var name is mangled/numbered.

### The two call paths (codegen at a `f(args)` value-call site)

Mirror `codecall` (`coder.lua:1233-1360`) for argument evaluation, then:

```c
TValue _fv = <callee>;
if (ttisCclosure(&_fv) && clCvalue(&_fv)->nupvalues >= 3
    && ttislightuserdata(&clCvalue(&_fv)->upvalue[1])
    && pvalue(&clCvalue(&_fv)->upvalue[1]) == <functag for T>) {
    /* PATH 1: exact match — unboxed native call */
    CClosure *_callee_mod = clCvalue(&clCvalue(&_fv)->upvalue[0]);
    <RETTYPE> (*_fp)(<native sig of T>) =
        ( /* function_sig(T, is_pointer=true) */ )
        titan_cast_func(..., pvalue(&clCvalue(&_fv)->upvalue[2]));
    res = _fp(L, _callee_mod, <unboxed args>, &outparams…);
} else {
    /* Try to call a callable value: boxed call through the Lua stack.
       Reserve slots via newslot/newtmp; push _fv, then boxed args
       (setslot per static param type); luaD_callnoyield(L, func, #R);
       read each result back with checkandget against R_i; restore L->top.p. */
}
```

- The fast-path function-pointer type comes from the **existing**
  `function_sig(name, T, is_pointer=true)` (`coder.lua:539-559`) — no new
  machinery. With `ctype(Type.Function)=TValue`, higher-order signatures pass
  function args by `TValue` and work automatically.
- **Statically-known direct calls** (callee resolves by name to a specific
  `TopLevelFunc`/`ModuleMember`/`StaticMethod`) keep the existing `codecall`
  fast path **unchanged** — only calls through a function-typed *value* use the
  new dispatch. Assigning to a top-level function identifier or module function
  identifier should be a compile-time error.
- **Slow-path stack discipline** (critical): account for the pushed function +
  `#P` args + `#R` results in the function's `nslots` (route through
  `newslot`/`newtmp`, like the array-fill code at `coder.lua:1557`); after reading
  results back, restore `L->top.p` to the function's invariant. Use
  `luaD_callnoyield` (lighter than public `lua_call`; Titan installs no
  continuations).

### Zero-return native ABI

- `function_sig`: when `#rettypes == 0`, `RETTYPE = "void"` and there are no
  out-params.
- `codefuncdec`/`genluaentry`: void native entry (no `res`, no first-return slot
  write; Lua entry returns `0`). `codereturn`: bare return → reset `L->top.p` and
  `return;`.
- Value-call of a `()` function: statement context only; `(f())` materializes a
  single `nil` `TValue`.

### GC barriers

- Storing light userdata (tag, native ptr) needs no barrier; `lua_pushcclosure`
  handles the `_mod` upvalue.
- A function value (boxed `TValue`) stored into a table/array/record-field/upvalue
  reuses the **existing** `setslot`/`setwrapped`/`copyslotwrapped` +
  `luaC_barrier`/`luaC_barrierback` sites, which already fire for `is_gc` types —
  and `types.is_gc(Function)` is already `true`. This works **provided** the
  `Type.Function` arms are added to those helpers so the barriers are emitted.

---

## Part 4 — Implementation plan (by workstream)

Ordered so each builds on the last. Compiler edits + compilation share one build
env and **cannot run in parallel unless using git worktrees**; rebuild the
active rock with `luarocks make --local` before any `busted`.

### Workstream A — Type system & zero-return canonical form (`types.lua`)
- `types.tostring`: emit `(P…) -> ()` for `#rettypes == 0` (currently emits just
  `(P…)` — ambiguous). Keep single/multi-return branches.
- Confirm `equals`/`compatible`/`serialize`/`is_gc` need **no change** (they
  already handle empty/nested rettypes). Add unit coverage (Part 5).

### Workstream B — Parser & checker frontend (`parser.lua`, `checker.lua`, `ast.lua`)
- `typefromnode["Ast.TypeFunction"]` (`checker.lua:137-142`): replace the error
  with construction of `types.Function(argtypes, rettypes, false)`, recursing on
  nested arrow returns; keep empty rettypes as `{}` (zero return).
- `Ast.ExpVar` (`checker.lua:873-891`): allow `Type.Function`, producing the
  function value; **keep** rejecting the record-type and module-alias branches;
  **reject** when the receiver is `Type.ForeignModule` (foreign function value).
- `Ast.StatAssign` (`checker.lua:426-453`): keep rejecting assignment *to a
  function name* (LHS `_decl` is a `TopLevelFunc`); allow assigning a value *into*
  a function-typed local/param/field.
- `Ast.ExpCall` (`checker.lua:1170-1205`): allow a `Type.Function`-typed callee
  (arity/type-check against `ftype.params`/`rettypes`); **keep** `'%s' is not a
  function but %s` for non-functions; **keep** instance-method handling.
- **Zero-return checking:**
  - **Change the default:** a missing return annotation now yields `rettypes = {}`
    (zero return), *not* `{Type.Nil()}`. This is in `parser.lua` `rettypeopt`
    (`:42-50`, currently defaults to `{ ast.TypeNil }`) and/or `checkfunc`
    (`checker.lua`, currently stores `{Type.Nil()}` for no-return). `: ()`
    annotation likewise → `rettypes = {}`.
  - `return` (0 exprs) is the legal return for a `()` function; `return nil` /
    `return expr` → arity error. The all-paths-return rule treats `()` like the old
    `nil` (may fall off the end), so the "can return nil but return type is not nil"
    enforcement does not apply to `()` functions.
  - A `#rettypes == 0` call used in expression context is an error except a
    parenthesized adjust `(f())` → single `nil` (find how parens are represented and
    thread a "value context vs statement vs adjust" signal; reuse the existing
    multi-return/`ExpExtra` adjustment machinery).
- Mark functions used as values (`node._valref`) in pass 2 for the coder.

### Workstream C — Coder slot/type plumbing (`coder.lua`)
Add a `Type.Function` arm (mirroring `Type.Value`/`Type.Option`) to: `ctype`
(`→ TValue`), `getslot` (`*($SRC)`), `setslot`/`setwrapped`/`copyslotwrapped`
(`setobj2t`), `initval` (`{ {0}, 0 }`), and a `checkandget` branch that mirrors the
one for `Type.Value`, since the check is deferred until trying to call. Add a
`codeexp` `Ast.ExpCast` arm for `→ Type.Function` (again, same as a cast to `Type.Value`).
`function_sig`: `void` return for zero-return types — note this is now the
**common** case (every unannotated function), so the `void` native entry, the
`return;` codegen, and the Lua entry returning `0` values must be solid, not a
rare corner.

### Workstream D — Coder function-value machinery (`coder.lua`)
- `allocate_upvalues` (`coder.lua:3213`): allocate a shadow slot per referenceable
  function (exported/static always; local if `_valref`), deterministically.
- Extended `CClosure` layout (push 2 light userdata after `titan_pushmodule`,
  count `3`); build-once-into-slot then copy into the module table for exports.
- Generate a Lua entry + closure for **local** referenced functions (today they
  have neither).
- Function-type tag emission + publish-or-recover phase, ordered **before** the
  function closures (Part 3), in the already-loaded `_init` branch.
- Reference-as-value codegen (read the shadow slot, boxed) for
  `VarName`/`VarDot` whose `_decl` is a top-level func / module-member func /
  static.
- Two-path dispatch in/around `codecall` for value-calls; statically-known
  direct calls unchanged.
- Zero-return codegen in `codefuncdec`/`genluaentry`/`codereturn`/`codecall`.

### Critical files
`titan-compiler/types.lua`, `titan-compiler/checker.lua`,
`titan-compiler/parser.lua`, `titan-compiler/ast.lua`, `titan-compiler/coder.lua`;
runtime headers `titan-runtime/titan.h` (only if a helper macro is convenient);
docs under `doc/language/` and `doc/implementation/`; specs under `spec/`.

---

## Part 5 — Testing plan

Follow existing conventions exactly: `spec/types_spec.lua` (pure, `types.*`
asserts), `spec/checker_spec.lua` (`run_checker`/`run_checker_modules`, reset
`types.registry`/`driver.imported`, `restrict`+subset asserts, `assert.match`
substrings), `spec/coder_spec.lua` (end-to-end: generate C, compile with `cc`,
run under `./lua`; multi-module via `generate_modules`+`call`;
`after_each` cleans repo-root artifacts).

**types_spec:** tostring/equals/compatible/serialize for no-arg, higher-order,
function-returning-function, and **zero-return `(integer) -> ()`** types;
exact-vs-compatible distinction (`(value)->integer` compatible but not equal to
`(integer)->integer`); serialize→`load`(env=`types`) round-trip for nested types;
`is_gc` on nested function types.

**checker_spec:** *Invert* the four rejection tests (`:454-460`, `:1892-1901`,
`:1914-1931`, and the `ExpCall` gate) to assert acceptance and the right `_type`.
*New positives:* function types in every annotation position; higher-order
`apply`; call-through-value; assign-into-function-typed-var; pass/return/store in
array/map/record; multi-return through a value; function↔value casts; cross-module
reference & boundary-pass (`run_checker_modules`); **zero-return / new default**:
an unannotated function (and an explicit `: ()`) has type `(...) -> ()`; `return
nil` in an unannotated/`()` function is now rejected; a `()`-call in expression
context is rejected; `(f())` accepted; `: nil` still gives a one-`nil` return.
*Must-stay rejections:* assign-to-function-name;
**method-as-value**; **foreign-function-as-value** (the single most important
negative — currently would wrongly succeed); non-function call; record-type/module
as value.

**coder_spec (end-to-end):** reference+call (fast path); `Point.new` as a value;
store-in-array/map/record then call; higher-order pass; return-then-call;
**slow path**; **multi-return through a value** (fast +
slow); function→value→function round-trip (+ a failing `value`→function call);
cross-module reference & boundary-pass; **exact-match tag agreement across
modules**; **Lua interop both directions** (Titan calls a passed Lua closure / C
function / `__call`; a Titan function value called from Lua; `f == g` identity);
`_types` serialization round-trip for an exported higher-order function;
**zero-return** end-to-end (`void` entry, statement call, `(f())`→nil); **GC
stress** (store a function value, allocate heavily + `collectgarbage`, then call —
covers the upvalue/array/record-field barriers; this is a new idiom in the spec).

*Harness note:* fast-vs-slow path can be observed from within Lua code called
by Titan through `debug.traceback`, since the fast path will not have the call
frame pushed by `luaD_callnoyield`.

**Docs:** rewrite `doc/language/functions.md` "Functions are not values (yet)";
update `index.md` status, `types.md`, `lua-interop.md` ("Calling Lua from Titan"
now supported), `records.md`, `expressions.md`, `grammar.md`, `option-types.md`,
`philosophy.md`, `ffi.md` (FFI funcs still not values); update
`doc/implementation/checker.md` (rejection points) and `index.md`; reconcile
`doc/first-class-functions-spec-v1.md` to "implemented"; add a dated
`doc/documentation-worklog.md` entry and move first-class functions out of the
"documented limitations" list (leaving closures/anonymous/methods/FFI there).
Document the zero-return `()` semantics and the **new default** in
`functions.md`/`statements.md`: rewrite the current claims that "a function
declared without `: type` returns `nil`" and that "`return` and `return nil` mean
the same thing" — the default is now `()` and `return` ≠ `return nil`. Note the
Lua-boundary behavior change (unannotated functions now return zero values) in
`lua-interop.md`.

**Audit existing tests & fixtures (consequence of the default change):** sweep
`spec/` and any `.titan` fixtures for unannotated functions (and `: nil`-relying
code) that (a) use `return nil` / `return expr`, or (b) are called in expression
context (e.g. `local x = voidfn()`). Update them to the new semantics (`return`,
or explicit `: nil`, or `(f())`/statement form). This is expected churn, not a
regression; budget for it in the implementation phase.

---

## Part 6 — Verification

- `luarocks make --local && busted` with the then-active rockspec — full suite green
  (current baseline 882; expect a net increase). Single files:
  `busted spec/coder_spec.lua`, etc.
- Smoke via the working tree directly (no rock): `./titanc <module>` on small
  fixtures exercising each path; for executables, a `main` that builds and applies
  function values.
- Manual end-to-end: a two-module example where B imports A, takes `A.f` as a
  value, calls it (fast path), passes a function across the boundary, and calls a
  Lua closure passed in from a `lua -l` driver; plus a `collectgarbage` stress.

---

## Part 7 — Workflow execution structure (for the follow-up dynamic workflow)

The build environment is a shared singleton: `luarocks make` installs into one
rocks tree, and the gitignored `lua-5.5.0` build plus the installed rock are what
`busted`/`./titanc` use. **Compiling and testing therefore always serialize** —
they cannot be parallelized even across git worktrees, because a fresh worktree
has no `lua-5.5.0` build and `luarocks make` from two trees would clobber the same
installed rock. What *can* parallelize is **editing**: an agent run with
`isolation: "worktree"` gets an isolated source checkout, so independent,
**non-compiling** edits fan out cleanly and the orchestrator integrates them.

Structure the workflow accordingly:

1. **Frontend** (Workstreams A+B) — *sequential, main tree.* One agent edits
   `types.lua`/`parser.lua`/`ast.lua`/`checker.lua` (coupled on the same files);
   verify with `spec/types_spec.lua` + `spec/checker_spec.lua` after `luarocks
   make --local`.
2. **Coder plumbing** (C) — *sequential, main tree.* Depends on the frontend
   types; verify a minimal end-to-end reference/call compiles & runs.
3. **Function-value machinery + dispatch + zero-return** (D) — *sequential, main
   tree.* The largest, most error-prone step; verify each path end-to-end as it
   lands. (Phases 1–3 are a dependency chain, so worktrees buy nothing here.)
4. **Test authoring** — *parallel via worktrees.* Fan out one worktree agent per
   spec file (`types_spec`, `checker_spec`, `coder_spec`) plus the fixtures audit;
   they only *write* `.lua`/`.titan`, no compilation. The orchestrator merges, then
   **runs `busted` serially** in the main tree after re-installing the rock.
5. **Docs** — *parallel via worktrees.* The doc files are independent; fan out one
   worktree agent per file/group, merge, then a single completeness-critic +
   link-check pass.

Between the sequential phases the orchestrator reads results and re-runs the suite
before proceeding. The two highest-risk areas — GC write barriers and cross-module
tag agreement — get dedicated **adversarial verification** agents (read-only
analysis, runnable in parallel) after phase 3.

Caveat for any worktree agent: do **not** run `busted`/`./titanc`/`luarocks make`
from a worktree (no `lua-5.5.0`, shared rock); restrict worktree work to source
edits and hand compilation/test runs back to the serial main-tree phase.

---

## Assumptions & open decisions

- **No-annotation default is `()` (decided).** `function f()` with no `: type` is
  `(…) -> ()` — zero returns — matching Lua. `return` (bare) is the only return;
  `return nil` is an arity error; `: nil` is the explicit one-`nil` form. This is a
  deliberate breaking change vs the old "unannotated = one `nil`, `return` ≡
  `return nil`" semantics, authorized because there is no production Titan code; it
  also makes Titan more Lua-faithful (`select('#', f())` is `0`). Cost: an audit
  and update of existing specs/fixtures (see Testing plan).
- **`mangle` for tags** uses verbatim canonical strings as registry keys and
  per-module numbered C identifiers, sidestepping identifier-collision risk.
