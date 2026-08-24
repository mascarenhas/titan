# Design plan: collapse records & modules to a single Lua 5.5 `Udata`

**Status:** IN IMPLEMENTATION (branch `records-modules-single-udata`). The
anonymous-functions work and its `_fn` ABI boundary are merged to `master`, so
the prerequisite ABI is frozen and only this feature advances it.

**Scope (decided by the owner): convert BOTH records AND modules to a single
`Udata`, and ELIMINATE the Lua-facing module table.** This supersedes the
earlier draft's recommendation to defer `_mod`. The two open "convert `_mod`?"
questions in §8 are now resolved as *yes*, plus a third change the draft did not
anticipate: the plain Lua *table* that a module currently hands to Lua (what
`require` returns today) is removed entirely — `require` returns the module
`Udata` itself, and its members are served through a metatable
(`__index`/`__newindex`) over a unified member map (see new §2.3).

**Owner's idea.** Titan was written for Lua 5.3, where a `Udata` held exactly
one `TValue`. So records use a **dual object**: a `CClosure` whose
`upvalue[]` array stores the real `TValue` slots (record fields), plus a `Udata`
wrapper holding that `CClosure` in its single user value `uv[0]` and carrying the
metatable. Modules are *almost* the same shape — a `CClosure` whose `upvalue[]`
holds the module's slots — except the module has **no `Udata` wrapper**: its
`upvalue[0]` is a plain Lua *table*, and that table (not the closure) is what
`require` returns and what Lua indexes for the module's functions/variables.

Lua 5.5 `Udata` can hold N user values (`luaS_newudata(L, rawsz, nuvalue)`,
accessed via `uv[i].uv`, written by the public `lua_setiuservalue` or by hand).
So the representation collapses to **one `Udata`** in both cases: the slots that
live in the `CClosure`'s upvalues become the `Udata`'s user values, the metatable
goes on the `Udata` directly, and for the module the separate Lua table
disappears — the `Udata` *is* the module value Lua sees. This removes one
allocation and one indirection per record, and one table allocation per module.

The non-obvious cost — analyzed in §4 and §3 — is that `_mod` and record
instances are typed `CClosure*` **throughout the native ABI**, and a write into
a `Udata` user value needs the **back** barrier (`luaC_barrierback`), whereas a
write into a `CClosure` upvalue needs the **forward** barrier (`luaC_barrier`).

All line numbers below are against the working tree at the time the draft was
written (`titan-compiler/coder.lua` ~4197 lines); the file has since grown to
~4543 lines, so treat the numbers as approximate landmarks, not exact offsets.

---

## 1. Current representation (precise)

### 1.0 Lua 5.5 `Udata` facts that the plan relies on

From `lua-5.5.0/src/lobject.h:491`:

```c
typedef struct Udata {
  CommonHeader;
  unsigned short nuvalue;   /* number of user values */
  size_t len;               /* number of raw bytes */
  struct Table *metatable;
  GCObject *gclist;
  UValue uv[1];             /* user values; uv[i].uv is a TValue */
} Udata;
```

- `udatamemoffset(nuv)` and `getudatamem(u)` (lobject.h:519-525) put the raw
  byte payload **after** the `uv[]` array. So the record type tag, currently
  stored at `getudatamem(_ud)` (one `void*`), keeps a *stable* access form
  (`*((void**)(getudatamem(_ud)))`) no matter how many user values the udata
  has — the macro recomputes the offset from `nuvalue`. **This is what makes
  the collapse cheap: the tag-read in `checkandget` need not change.**
- `luaS_newudata(L, s, nuvalue)` (lstring.c:286) nil-fills all `nuvalue` user
  values and sets `metatable = NULL`. A udata with `nuvalue > 0` carries a
  `gclist` and is traversed by the GC (so its user values are real GC roots).
- **Barrier kind (critical).** `lua_setiuservalue` (lapi.c:1004) does:
  ```c
  setobj(L, &uvalue(o)->uv[n-1].uv, s2v(L->top.p - 1));
  luaC_barrierback(L, gcvalue(o), s2v(L->top.p - 1));   /* BACK barrier */
  ```
  Compare CClosure upvalue stores, which Titan currently barriers with the
  **forward** `luaC_barrier(L, closure, slot)` (e.g. coder.lua:1017, 1043,
  2040, 3506). **Every store that moves from a CClosure upvalue to a Udata user
  value flips barrier direction** (§3).

### 1.1 Module state container `_mod` (a `CClosure`)

- Created in `_init` (coder.lua:3493): `_mod = luaF_newCclosure(L, NUPVALS)`,
  upvalues nil-filled.
- `NUPVALS = tlcontext.upvalue + 1` (coder.lua:4180).
- Upvalue layout, assigned by `allocate_upvalues` (coder.lua:3815) and
  `nextupvalue` (coder.lua:86, pre-increment from 0):
  - `upvalue[0]` = the Lua-visible **module table** (`require` returns this;
    built coder.lua:3504-3506, with a forward barrier).
  - `upvalue[1..V]` = **exported module variables**, declaration order. These
    indices are **module ABI** — importers recompute them from the serialized
    interface (`import_module`, coder.lua:3570-3576).
  - next: **canonical-closure slot for every exported function** (V+1..V+F,
    coder.lua:3827-3835) — used so an imported function value is reachable by
    index (`codevar` Type.ModuleMember path, coder.lua:1789-1799).
  - next: **local module variables** and **imported-module closures**
    (coder.lua:3836-3845).
  - next, lazily during codegen: **referenced local-function closures and
    record-static closures** (coder.lua:3848-3858; `static_slots` map),
    **record metatables** (`type2metatable`, coder.lua:146-151), and
    **cross-module method modules** (`ctx.modules`, coder.lua:1523-1528).
- `_mod` is passed to **every** native entry as the 2nd parameter
  (`function_sig`, coder.lua:568) and recovered by every Lua wrapper from its
  own closure's `upvalue[0]` (genluaentry, coder.lua:3032-3033:
  `_fn = clCvalue(s2v(func)); _mod = clCvalue(&_fn->upvalue[0])`).
- The module table's metatable carries `__index`/`__newindex` (coder.lua:4051,
  4067) that serve exported variables to Lua via a name→slot varmap; they read
  `_mod = clCvalue(&_me->upvalue[0])` and index `_mod->upvalue[slot]`.

There is **no Udata wrapper for the module itself.** `require` returns
`_mod->upvalue[0]` (the plain Lua table, postamble). The module table holds the
exported **functions** as direct named fields (installed in `$FUNCS` via
`lua_setfield`) and a **subtable per record** (the record's static namespace,
e.g. `Point` holding `Point.new`); exported **variables** are served by the
table's metatable `__index`/`__newindex` (functions carrying `_mod` + a
name→slot `varmap`, built in `create_meta`). So the "dual object" framing applies
in full only to **records**; the module is a bare `CClosure` whose `upvalue[0]`
happens to be a table.

**This plan removes that table.** After the change `_mod` is a `Udata`, `require`
returns the `Udata`, and *all* Lua-facing member access (functions, variables,
record namespaces) flows through a metatable installed on the `Udata` — see new
§2.3. Functions and record namespaces already need to be reachable by index from
Titan code (canonical-closure slots), so folding them into the same member-map
`__index` that already serves variables is a natural unification, not a new
mechanism.

### 1.2 Record instances (the true dual object)

Built by `coderecord` (coder.lua:2018-2082). For a record with N fields:

```c
_tmp_1 = luaF_newCclosure(L, N+1);                 /* upvalue[0]=wrapper, 1..N=fields */
memset(_tmp_1->upvalue, 0, sizeof(TValue) * (N+1));
setclCvalue(L, _tmp_1_slot, _tmp_1);               /* anchor closure first */
{
    Udata* _ud = luaS_newudata(L, sizeof(void*), 1);  /* 1 user value */
    *((void**)(getudatamem(_ud))) = (void*)test_Point_typetag;   /* type tag */
    _ud->metatable = hvalue(&_mod->upvalue[META]);                /* metatable */
    setclCvalue(L, &_ud->uv[0].uv, _tmp_1);          /* uv[0] = back-ref to closure */
    setuvalue(L, &(_tmp_1->upvalue[0]), _ud);        /* upvalue[0] = forward-ref to udata */
    luaC_barrier(L, _tmp_1, &(_tmp_1->upvalue[0]));  /* forward barrier */
}
/* then per field: setslot into &(_tmp_1->upvalue[field.index]) + luaC_barrier */
```

- **Closure**: `upvalue[0]` = the wrapper udata; `upvalue[i]` (1-based) = field
  `i` (index assigned by checker `types.Field`).
- **Udata**: payload = `sizeof(void*)` holding the type tag; `uv[0].uv` = the
  closure (back-ref); `metatable` set from the module upvalue caching this
  record's metatable.
- `ctype(Type.Nominal)` = `CClosure*` (coder.lua:542). So **inside Titan, a
  record value is the CClosure**: parameters, locals, returns are all
  `CClosure*`.
- Field read = `getslot` of `&((rec)->upvalue[index])` (codevar, coder.lua:1785;
  `getslot` Nominal returns `clCvalue($SRC)`, coder.lua:60).
- Field write = `setslot` into `&(_recobj->upvalue[index])` + **forward**
  `luaC_barrier(L, _recobj, _fieldslot)` (codeassignment, coder.lua:1006-1017).
- Lua boundary out (`setwrapped`, coder.lua:458-465): hand Lua
  `&((rec)->upvalue[0])` — i.e. the wrapper udata.
- Lua boundary in (`checkandget` Nominal, coder.lua:270-300): verify the tag at
  `getudatamem`, then `clCvalue(&_ud->uv[0].uv)` to recover the closure.
- `copyslotwrapped` (coder.lua:482-509) and the record `__index` getswitch
  (coder.lua:3666-3668) also reach through `clCvalue(_slot)->upvalue[0]` to get
  the wrapper.

### 1.3 Record statics & methods

- **Statics** (`new`, synthesized): `Ast.TopLevelStatic`. The native entry is
  `static_name(typ)` with the normal `(L,_mod,_fn,params...)` ABI (codefuncdec,
  coder.lua:3092). `new`'s body is a record constructor expression — it calls
  `coderecord`. A static gets a **canonical-closure slot** in `_mod`
  (allocate_upvalues coder.lua:3852-3855, `static_slots`), and a 3-upvalue
  Lua-callable CClosure (upvalue[0]=_mod, [1]=type tag, [2]=native ptr) is built
  into both that slot and the record subtable (coder.lua:4000-4018). `Rec.new`
  is a first-class value.
- **Methods** (`Ast.TopLevelMethod`): native entry `method_name(typ)` with
  `self` as the first real parameter, named `__self__`, typed
  `ctype(Type.Nominal)` = `CClosure*` (codefuncdec coder.lua:3093-3100). A
  method's Lua entry is installed into the record metatable's `__index` fieldmap
  as a 1-upvalue (`_mod`) CClosure (coderecorddec coder.lua:3681-3690). Methods
  are **not** first-class (no shadow slot).
- Both `self` and any record-typed parameter/return are `CClosure*` end to end.

### 1.4 Module variables & cross-module imports

- **Own module variable** read: `getslot(&_mod->upvalue[SLOT])` (codevar
  coder.lua:1821-1822 via `node._decl._slot`); write:
  `setslot(_mod->upvalue[SLOT]) + luaC_barrier(L, _mod, slot)` (codevardec
  coder.lua:3408-3410; codeassignment coder.lua:1040-1045).
- **Imported module variable** read:
  `getslot(&(clCvalue(&_mod->upvalue[MODINDEX])->upvalue[VARINDEX]))` (codevar
  coder.lua:1815-1818); write: same chain + `luaC_barrier(L, _imod, _varslot)`
  (codeassignment coder.lua:1026-1039). `_imod = clCvalue(&_mod->upvalue[MODINDEX])`.
- **Imported function value** read:
  `&(clCvalue(&_mod->upvalue[MODINDEX])->upvalue[FNINDEX])` (codevar
  coder.lua:1795-1799).
- **Static-linked import**: `extern CClosure *dep_init(...)`; in `_init`,
  `_m = dep_init(L); setclCvalue(L, &_mod->upvalue[INDEX], _m)` (import_module
  coder.lua:3554-3563).
- **Dynamic (.so-only) import**: dlopen + dlsym the `dep_init` symbol, store its
  returned `CClosure*` into the module slot (import_module coder.lua:3542-3553).
  `<mangled>_init` **returns `CClosure*`** — this is part of the cross-`.so` ABI
  (it is the return type of `import_module`'s extern decl and the dlsym cast).
- Imported-record **metatables** and **tags** are wired through the Lua registry
  at init time (`init_data_from_other_modules` coder.lua:3611-3632), not through
  symbols.

---

## 2. Proposed single-`Udata` representation

The core swap: **what is in a `CClosure`'s `upvalue[]` becomes a `Udata`'s
`uv[]`**; the metatable goes on the `Udata`; the tag stays in the raw payload.

### 2.1 Records (the primary, clearly-worthwhile case)

**Construction** (rewrite `coderecord`, coder.lua:2018-2082):

```c
/* one allocation: N user values for fields (1-based -> use uv[0..N-1], or keep
   1-based by allocating N+1 and leaving uv[0] unused for index symmetry) */
Udata* _ud = luaS_newudata(L, sizeof(void*), N);     /* or N, see field indexing */
setuvalue(L, _tmp_1_slot, _ud);                       /* anchor the udata */
*((void**)(getudatamem(_ud))) = (void*)test_Point_typetag;
_ud->metatable = hvalue(&_mod->upvalue[META]);        /* metatable directly on udata */
/* per field i: store value into &_ud->uv[i].uv + luaC_barrierback(L, obj2gco(_ud), &_ud->uv[i].uv) */
```

No `luaF_newCclosure`, no back-and-forth links, no
`setuvalue(&closure->upvalue[0], _ud) + luaC_barrier`.

**Field indexing decision.** Fields are currently 1-based with `upvalue[0]`
reserved for the wrapper (checker `types.Field` indices). Two options:

- **(a) Keep 1-based indices, allocate `N` user values but address `uv[index-1]`**
  (rebase by 1 in the templates). Touches every field-access template but keeps
  the checker's `types.Field.index` untouched and saves one slot.
- **(b) Keep `N+1` user values, leave `uv[0]` unused**, so `uv[index]` matches
  today's `upvalue[index]` verbatim. Wastes one `TValue` per record but makes
  the template diff minimal (just `->upvalue[i]` → `->uv[i].uv`). **Recommended
  for the first cut** — it minimizes risk; an index rebase can be a follow-up.

**`ctype(Type.Nominal)`** (coder.lua:542): `CClosure*` → **`Udata*`** (see §4
for the ABI fan-out this triggers — this is the expensive part).

**Access-site rewrites** (mechanical, all in coder.lua):

| Site | Now | Proposed |
| --- | --- | --- |
| `getslot` Nominal (60) | `clCvalue($SRC)` | `uvalue($SRC)` |
| `setslot` Nominal (448) | `setclCvalue(L, $DST, $SRC)` | `setuvalue(L, $DST, $SRC)` |
| field read (codevar 1785) | `&(($EXP)->upvalue[$INDEX])` | `&(uvalue(...)->uv[$INDEX].uv)` (or via the `Udata*` C var) |
| field write (codeassignment 1006-1017) | `&(_recobj->upvalue[$INDEX])` + `luaC_barrier(L, _recobj, slot)` | `&(_ud->uv[$INDEX].uv)` + **`luaC_barrierback(L, obj2gco(_ud), slot)`** |
| `setwrapped` Nominal (461) | `&(($SRC)->upvalue[0])` | `&_udval` where `_udval` is a `TValue` set by `setuvalue` from the `Udata*` — **no upvalue[0] hop; the value to hand Lua IS the udata** |
| `copyslotwrapped` Nominal (485) | `&(clCvalue($SRC)->upvalue[0])` | the udata itself (`$SRC` is already the wrapper) |
| `checkandget` Nominal (270-300) | tag check unchanged; `clCvalue(&_ud->uv[0].uv)` | **drop the back-ref hop** — `$VAR = _ud;` (the udata is the value) |
| record `__index` getswitch (3666) | `clCvalue(_slot)->upvalue[0]` for nominal field | the nominal field value is itself a udata; hand it out directly |
| record `__index`/`__newindex` (3694-3738) | `_rec` is `CClosure*` via checkandget; fields at `_rec->upvalue[i]` | `_rec` is `Udata*`; fields at `_rec->uv[i].uv`; **`luaC_barrier(L,_rec,_dst)` → `luaC_barrierback(L, obj2gco(_rec), _dst)`** |

Crucially: once a record value *is* the udata, `setwrapped`, `copyslotwrapped`,
and `checkandget`'s back-ref all simplify (the wrapper and the value are one
object). This deletes the very indirection the migration doc calls "Closure and
udata reference each other".

### 2.2 Modules (`_mod`) — optional, see §4

If `_mod` becomes a `Udata*`:

- `upvalue[i]` → `uv[i].uv` everywhere `_mod` is indexed (dozens of sites:
  1028, 1487, 1503, 1526, 1796, 1815, 3395, 3478, 3505, 3551, 3561, 3626, 3637,
  3952, 3983, 4006, 4053, 4070, 4108, init template 3494-3506, …).
- `upvalue[0]` (module table) → `uv[0].uv`; metatable now lives on the udata
  itself (but **the module table, not the udata, is what `require` returns**, so
  the module's metatable placement is unaffected — the module table keeps its
  own metatable; the udata's own metatable can stay NULL or be unused).
- `luaF_newCclosure(L, NUPVALS)` → `luaS_newudata(L, 0, NUPVALS)`.
- **forward `luaC_barrier(L, _mod, slot)` → back `luaC_barrierback(L, obj2gco(_mod), slot)`** at every module-slot store (1043, 3410, 3439, 3506, 3953, 3984, 4007, codeassignment imported-var 1036, plus codevardec switch_set 3439).
- `<mangled>_init` return type `CClosure*` → `Udata*` (ABI change, see §6).
- genluaentry `_mod` recovery (3033): `clCvalue(&_fn->upvalue[0])` →
  `uvalue(&_fn->upvalue[0])` — but note **`_fn` is and must remain a
  CClosure** (it is a callable function value), so its upvalue[0] still holds
  whatever `_mod` is; only the *read accessor* of the stored `_mod` changes.
- `titan_pushmodule` (titan.h) pushes `_mod` with `setclCvalue` → `setuvalue`.

**Decision: convert `_mod` to a `Udata`.** (The draft recommended deferring this;
the owner has chosen to do it now, together with the table removal below.)

### 2.3 Eliminating the Lua-facing module table

Today `require` returns `_mod->upvalue[0]`, a plain Lua table that holds the
exported functions (direct fields) and record namespaces (subtables), with a
metatable serving variables. After this change there is **no such table**:
`require` returns the module `Udata`, and a metatable on the `Udata` serves every
member. The module member slots are **0-based** (the old `uv[0]` table slot is
gone, not merely reserved): `import_module`'s slot recomputation enumerates
variables `0..V-1`, then function closures `V..V+F-1`, matching the imported
module's 0-based `nextupvalue`. (The first cut reserved `uv[0]` to keep slot math
verbatim; the 0-based rebase shifted both the allocator and the importer.)

**Unified member map.** The existing variable `varmap` (name→slot) and
`__index`/`__newindex` switch are generalized to cover all three exported member
kinds. For each module the coder now emits a single name→slot map plus matching
switch cases:

| Member kind | `__index` case | `__newindex` case |
| --- | --- | --- |
| exported **variable** (slot 1..V) | `copyslotwrapped(type, top-1, &_mod->uv[slot].uv)` (coerce out) | `checkandset` + back barrier |
| exported **function** (canonical-closure slot, already allocated) | push the closure value: `setobj2s(L, top-1, &_mod->uv[slot].uv)` | error "cannot assign to function" |
| **record namespace** (new uv slot, holds the static-namespace table) | push the table value: `setobj2s(L, top-1, &_mod->uv[slot].uv)` | error |

Functions already live in canonical-closure uv slots (`allocate_upvalues` gives
every exported function one, used for first-class refs and by importers), so
serving `m.f` from that slot via `__index` removes the `lua_setfield` into the
(now-gone) module table without adding storage. Record namespaces get a **new**
per-record uv slot (allocated in the *late* group, after importer-visible slots,
so importer slot math is unchanged); the namespace table is built once in
`$FUNCS`, stored into that slot (back barrier), and its statics installed into it
(reached from the slot instead of `lua_getfield` off the module table).

**Metatable install** (`create_meta`): build the metatable with the
`__index`/`__newindex` member-map closures (each still carries `_mod` +
the name→slot table as upvalues; `_mod` now recovered with `uvalue`) and a
`__metatable` protection string, then set it on the **`Udata`** (push the udata
via `titan_pushmodule`, `lua_setmetatable`), not on a table. Because every module
that exports anything now needs this metatable for *function* access (not just
variable access), the `#switch_get > 0` gate becomes "module has any exported
member" — true for essentially every real module.

**`__index`/`__newindex` bodies**: recover `_mod` from the closure's
`upvalue[0]` with `uvalue` (was `clCvalue`); the variable switch reads/writes
`&_mod->uv[slot].uv` (was `->upvalue[slot]`) and the variable-write barrier flips
forward→back. The "not found" error message generalizes from "global variable
'%s'" to "member '%s'" since functions/records now route here too.

**postamble**:

```c
int $LUAOPEN_NAME(lua_State *L) {
    Udata *mod = $INITNAME(L);          /* was CClosure* */
    setuvalue(L, L->top.p, mod);        /* was setobj2s(..., &mod->upvalue[0]) */
    L->top.p++;
    return 1;
}
```

**Init**: `_mod = luaS_newudata(L, 0, $NUPVALS)` (was `luaF_newCclosure`); the
`lua_newtable; setobj2t(&_mod->upvalue[0], ...)` block that built the module table
is **deleted**; the registry-anchor / re-entry stores `_mod` as the udata
(`uvalue(s2v(L->top.p - 1))` on the re-entry read).

**What stays a table** (and is fine — none of these is "the module table" the
owner asked to remove): the metatable itself, the name→slot member map (a
metamethod implementation detail, like a record's fieldmap), per-record static
namespace tables (`m.Rec` must return an indexable namespace; `m.Rec.new` and
`m.Rec.new == m.Rec.new` are exercised by the specs), and record/array/map
metatables.

---

## 3. GC / barrier implications (the sharp edge)

**Rule:** a store into a `CClosure` upvalue uses the **forward**
`luaC_barrier(L, closure, slot)`; a store into a `Udata` user value uses the
**back** `luaC_barrierback(L, obj2gco(udata), value)` (proven by
`lua_setiuservalue`, lapi.c:1015). The semantics differ:
forward greys/recolors the *value*; back re-greys the *container*. They are
**not interchangeable** — using the wrong one under the generational collector
is "near-deterministic corruption" (per CLAUDE.md), not a rare race.

Note the argument shape also differs: forward takes the **slot pointer**
(`luaC_barrier(L, o, slotptr)`); back takes the **value** and an
`obj2gco`-wrapped container (`luaC_barrierback(L, obj2gco(o), valueptr)`).
Templates must change both the macro name *and* its arguments.

**Every store site that flips forward→back when its container becomes a Udata:**

Records (always change — records become Udata in the first cut):

1. `coderecord` field fill — coder.lua:2072-2078 (currently forward `luaC_barrier(L, $TMPNAME, $SLOT)`).
2. `coderecord` wrapper-link store — coder.lua:2037-2040 — **deleted entirely**
   (no more back-ref; the value is the udata).
3. Record field assignment — `codeassignment` Ast.VarDot/Type.Field,
   coder.lua:1016-1017.
4. Record `__newindex` — coder.lua:3733 (`luaC_barrier(L, _rec, _dst)`).
5. Record static `new` builds via `coderecord` (covered by 1-3).

Modules (**only if** §4 decides to convert `_mod`; otherwise unchanged):

6. Own module-variable assignment — codeassignment coder.lua:1043.
7. Imported module-variable assignment — codeassignment coder.lua:1036
   (`luaC_barrier(L, _imod, _varslot)`; `_imod` becomes `Udata*`).
8. Module-variable init — codevardec coder.lua:3410.
9. Module `__newindex` setter switch — codevardec switch_set coder.lua:3439.
10. Module table store into slot 0 — init template coder.lua:3506.
11. Canonical-closure publish into module slots — coder.lua:3953, 3984, 4007.
12. Imported-module-closure store in `_init` — import_module coder.lua:3551,
    3561 (`setclCvalue(L, &_mod->upvalue[INDEX], _m)` → `setuvalue` + back
    barrier; note these currently emit **no** barrier because they run during
    `_init` right after `_mod` is freshly white-allocated — re-audit whether a
    barrier is needed once `_mod` is a Udata with `gclist`).
13. init_data_from_other_modules metatable/module stores — coder.lua:3626, 3637
    (currently `setobj2t` with no barrier, same fresh-`_mod` reasoning;
    re-audit).

**Stores that stay forward (containers that remain CClosures):** every
`_fn->upvalue[i]`, every capture box `box->upvalue[0]` (codeboxparam 3050-3052,
codeassignment 1051-1066, newbox 682-683), the canonical function/static
closures (3-upvalue CClosures), lambda closures (codelambda 3247-3263). These
are function *values* and **stay CClosures** (§5).

**`luaS_newudata` can trigger an emergency GC** (it allocates). The current
record code already guards this with "anchor the closure first, then barrier the
wrapper store" (coder.lua:2031, 2040 + the comment). In the new scheme the udata
*is* the value, so the discipline is simpler: `luaS_newudata` returns the object
already nil-filled and white; anchor it in its stack slot immediately
(`setuvalue(L, _tmp_slot, _ud)`), then fill fields with back barriers. The
fields are stored *after* the udata is anchored, so an emergency GC during a
field's own evaluation can't lose the half-built record (it's anchored), and the
back barrier on each field store keeps the (possibly old/black) udata honest.

**`obj2gco` availability.** `luaC_barrierback` wants `GCObject*`; the array/map
write paths already use `luaC_barrierback(L, obj2gco(_t), v)` (coder.lua:1121,
1155, 1932, 2008), so `obj2gco` is in scope and the pattern is established.

---

## 4. The `_mod` ABI question + `Type.Nominal` ctype fan-out

### 4.1 Why this is the crux

`_mod` is `CClosure*` in **every** native signature (`function_sig`
coder.lua:568 unconditionally emits `"CClosure *_mod"`). It appears in:
`function_sig` (forward decls, function-pointer typedefs for the value-call fast
path at 1435, and the `.so` dlsym casts at 3607), every `codefuncdec`/
`codelambdadec` param list (3092, 3313), `genluaentry` (3032-3033, 2950), the
value-call fast path (`_vc_mod = clCvalue(&_vc_callee->upvalue[0])`, 1415), and
the call-site `modarg` expressions (1487, 1503, 1526). Changing `_mod`'s C type
is a **whole-ABI change** of the same scope as the just-completed `_fn`
addition (commit `698e952` "closures phase 1: add _fn native-ABI parameter").

`Type.Nominal`'s ctype changing from `CClosure*` to `Udata*` is **also** an ABI
fan-out, but a *necessary* one for the records simplification: every
record-typed parameter, return, local, `self`, and out-param changes C type
(`function_sig` 573/576, codefuncdec params 3099/3114/3118, genluaentry
2956/2962, `coderecord` temp type via `ctype`, newtmp 633). The value-call fast
path's function-pointer typedef (`function_sig(fptype, ftype, true)`, 1435) and
the `.so` function-pointer signatures (3594, 3607) must agree, so a
record-returning or record-taking function's pointer type changes too — but this
falls out automatically from `ctype` because all those go through
`function_sig`→`ctype`.

### 4.2 Cost comparison

| Change | ABI impact | User-visible payoff | Verdict |
| --- | --- | --- | --- |
| Record instance: `CClosure*`→`Udata*` (Type.Nominal ctype) | Large but mechanical, **forced** by the records collapse | 1 fewer alloc + 1 fewer indirection per record; simpler wrap/unwrap | **Do it** (this is the point) |
| `_mod`: `CClosure*`→`Udata*` | Large, mirrors the `_fn` churn | Enables removing the separate module *table* entirely (the `Udata` becomes the module value Lua sees, with its own metatable), which is the owner's actual goal here — not merely uniformity | **Do it** (owner's decision; §2.2/§2.3) |

The records change is unavoidable if we want the single-object win for the case
that actually allocates per value (records can be created in hot loops; module
closures are created once per module per state). `_mod` conversion is pure
uniformity with a real ABI cost and essentially zero runtime benefit, so it
should be a **separate decision** the owner makes (§8).

### 4.3 If `_mod` is NOT converted: a representational wrinkle

If records become `Udata` but `_mod` stays a `CClosure`, the two "containers"
diverge: `_mod` upvalues use forward barriers, record fields use back barriers.
That is **fine** — the barrier kind is chosen per container type, and the coder
already chooses barriers per call-site. The only care needed: helper functions
that today assume `CClosure*` for both (e.g. nothing currently shares a helper
across record-field and module-slot stores — they are separate templates), so no
shared abstraction breaks. The plan keeps them separate, which they already are.

---

## 5. Interaction with first-class functions / closures (the boundary)

**What MUST stay a `CClosure`:** every *callable function value*. A Titan
function value is a real `CClosure` Lua can call (`luaD_callnoyield`), with
`upvalue[0]=_mod`, `[1]=type tag (light userdata)`, `[2]=native ptr (light
userdata)`, `[3+i]=captures`. This is load-bearing in:

- the value-call fast path (`ttisCclosure(&fn) && nupvalues >= 3 && ...`,
  coder.lua:1410-1418) — it dispatches on the closure shape.
- canonical function/static closures (3947-4018), referenced-local-function and
  record-static shadow slots.
- lambda closures (`codelambda` 3229-3282, `codelambdadec` 3289+), capture boxes
  (`newbox` 677-683, a 1-upvalue CClosure cell).
- the `_fn` parameter and capture reads (`_fn->upvalue[3+i]`, 3214, 3307).

None of these change. They are function *values*, not data containers, and Lua
must be able to *call* them — only a `CClosure`/`LClosure`/`CFunction` is
callable. **The simplification is strictly about records (and optionally
modules) as data containers.**

**Explicit boundary table:**

| Object | Today | After plan |
| --- | --- | --- |
| Record instance | CClosure + Udata wrapper | **single Udata** |
| `_mod` module state | CClosure (table in uv[0]) | CClosure (unchanged) — or Udata if §8 says so |
| Function value (top-level, imported, static `new`, lambda) | CClosure | **CClosure (unchanged)** |
| Capture box cell | 1-upvalue CClosure | **CClosure (unchanged)** |
| Function-type tag / native ptr | light userdata in closure upvalues | unchanged |
| Record metatable | Table in `_mod` upvalue | unchanged (still cached in `_mod`, now on the udata's `metatable` field) |

One subtlety: a record field can hold a **function value** (records.md:212-216).
That field's stored value is a boxed `TValue` (a CClosure) living in the record's
`uv[i].uv` — fine, a Udata user value holds any `TValue`. Reading it back is
`getslot(Type.Function)` = `*($SRC)` (boxed), unaffected by the container being a
Udata.

---

## 6. Migration / sequencing & cross-`.so` ABI

1. **Land after anonymous functions.** Recent history: `698e952` (`_fn` ABI
   boundary), `ed7e40f`/`77b8508` (anon-fn frontend + closure
   codegen). This plan is the **next** big ABI change; doing it on top of an
   unsettled `_fn` ABI would mean two moving ABIs at once. Wait until the
   anon-functions branch is merged and stable.
2. **New ABI boundary.** Update the authoritative ABI marker and document that
   record instances are a single Udata (rather than CClosure+Udata), so the
   native ABI of every function
   taking/returning a record changed; `<mangled>_init`'s return type changed
   only if `_mod` was also converted. `.so` modules compiled before this
   boundary are ABI-incompatible and must be rebuilt.
3. **Cross-`.so` interface recovery (`<mangled>_types`) keeps working unchanged**
   — it serializes *checker types* (`types.serialize`, coder.lua:4139), which are
   representation-agnostic. Records still serialize as `Type.Record`/nominal; the
   C representation is invisible to the interface. The `.so`-only import path
   (so_import_spec, so_rehydration_spec) recovers types from this symbol, not
   from C layout, so it is unaffected at the type level.
4. **But the `.so` native-call ABI does change** for record-typed functions
   (param/return ctype `CClosure*`→`Udata*`): the `static`-function-pointer
   decls in `init_data_from_other_modules` (coder.lua:3594, 3607) and the
   fast-path typedef (1435) regenerate from `ctype`, so callers and `.so`
   callees built on the same side of the boundary agree; a mixed pair does not.
   Verify `build_so_chain`/`so_check` still pass (they build the
   dep `.so` from memory and assert dynamic resolution).
5. **If `_mod` is converted (only if §8 chooses to):** `<mangled>_init`'s return
   type changes `CClosure*`→`Udata*`, which appears in `import_module`'s extern
   decl (3555) and dlsym cast (3549). That is an additional cross-`.so` ABI point
   — another reason to keep `_mod` as a CClosure unless the owner wants it.
6. **Docs to update:** `doc/lua-5.5-migration.md` (the "Records" section
   describing the CClosure+Udata scheme, lines ~127-146 and the review findings
   referencing the wrapper store barrier #3), `doc/language/records.md` (the
   "Performance notes" / "Implementation note" §, lines 433-447 — "allocates two
   small heap objects" becomes one; "dual representation" note), and
   `doc/implementation/values-and-gc.md` (§"Records: a CClosure wearing a Udata",
   97-253; §"Wrap and unwrap", 205-253) + `doc/implementation/codegen-overview.md`
   / `codegen-constructs.md` / `lua-interop-internals.md` record sections.

**Suggested step order within the change:**

1. Flip `ctype(Type.Nominal)` to `Udata*`; rewrite the leaf accessors
   (`getslot`/`setslot` Nominal, `checkandget`/`checkandset` Nominal). Compile —
   expect type errors everywhere a record value is used; fix mechanically.
2. Rewrite `coderecord` (single `luaS_newudata`, back-barrier field fills,
   delete the wrapper-link block).
3. Rewrite field access (codevar 1785, codeassignment 1006-1017), `setwrapped`/
   `copyslotwrapped`, record `__index`/`__newindex` (3694-3738) incl. the back
   barrier.
4. Rewrite the record getswitch nominal arm (3666-3668) and the static/method
   `self`-typed paths (these fall out of `ctype`).
5. Run `spec/checker/*` then `spec/coder/coder_spec.lua` then the `.so` specs.
6. **(Optional, gated on §8)** convert `_mod` to `Udata` in a separate commit.
7. Advance the ABI marker and update docs.

---

## 7. Testing strategy & risk list

### Regression oracle (existing specs — run from repo root after `luarocks make`)

- **`spec/coder/coder_spec.lua`** (end-to-end: generate C, `cc`, run under
  `./lua`). The authoritative record oracle — record construction,
  field read/write, methods, nested records, `Rec.new`, records crossing to/from
  Lua (`type(p)=="userdata"`, identity, protected metatable, field type-check
  errors `expected float but found string`, nominal mismatch errors
  `expected test.Rec but found test.Point` / `... but found number`), records in
  arrays/maps/`value`, option-records, mutation visibility.
- **`spec/coder/so_import_spec.lua`** — cross-`.so` records (function/record use
  across the dlopen boundary, transitive `.so`→`.so`, first-class fast path
  across `.so`). Confirms the new ABI is self-consistent across separately
  compiled `.so`s.
- **`spec/checker/so_rehydration_spec.lua`** — interface recovery from
  `<mangled>_types` (must be unaffected; a good "did I accidentally change the
  serialized interface" tripwire).
- **`spec/coder/first_class_functions_spec.lua` + `spec/coder/closures_spec.lua`**
  — guard the boundary in §5: function values, captures, the value-call fast
  path, `Rec.new` as a value, function-typed record fields. These MUST stay
  green untouched — they prove the simplification did not leak into function
  values.
- **`spec/checker/*`** — pure type-level; should be entirely unaffected (the
  change is representational, not type-system). If any checker spec breaks,
  something leaked from coder into checker (a smell).

### New tests to add

- A record with a **GC-able field mutated in a hot loop** (forces minor
  collections between field writes) — pins the forward→back barrier flip. Ideal
  to run under a GC-stress build (`luaC_fullgc`/aggressive minor GC) the way the
  migration's barrier findings were reproduced.
- A record stored into a module variable and into an array, then mutated, then
  read back after a forced GC — exercises back barrier + container reachability.
- A record whose field is **another record** (nested), read out to Lua and back,
  asserting identity (the deleted back-ref hop must not break nested unwrap).
- An **empty record** (records.md:31) — `luaS_newudata(L, sizeof(void*), 0 or 1)`
  edge (with the §2.1(b) layout, an empty record still allocates 1 unused
  user value; verify `getudatamem` tag access still works with `nuvalue` small).

### Risk list

1. **Barrier-direction bugs (highest).** Forward where back is needed (or vice
   versa) is silent corruption under the generational default. Mitigate: a
   single audited table (§3) of every flipped site; GC-stress test; mirror
   `lua_setiuservalue` exactly for the argument shape (`obj2gco`, value not slot).
2. **ABI fan-out missed in one path.** A record-typed param/return whose
   `function_sig` regenerates correctly but a hand-written cast (the `.so` dlsym
   cast 3607, the fast-path typedef 1435) drifts → crash at a `.so` boundary.
   Mitigate: all those go through `function_sig`/`ctype`; grep for any literal
   `CClosure*` in record-context templates after the change.
3. **Field index off-by-one** if option §2.1(a) (rebase to 0-based) is chosen.
   Mitigate: start with §2.1(b) (keep `N+1`, `uv[0]` unused, indices verbatim).
4. **The `setuvalue`/`uvalue` vs `setclCvalue`/`clCvalue` swap missed at a
   wrap/unwrap site** → handing Lua a CClosure (uncallable as a record) or
   reading a udata as a closure (`clCvalue` on a udata is UB). Mitigate: the
   migration-era specs (`type(p)=="userdata"`, field access from Lua) catch this
   immediately.
5. **`_init` fresh-`_mod` no-barrier assumptions** (sites 12-13 in §3) become
   wrong if `_mod` is converted to a Udata with a `gclist` that an emergency GC
   can blacken between allocation and store. Mitigate: keep `_mod` a CClosure
   (recommended), or re-audit those stores if converting.
6. **`pretty.reindent_c` cosmetic breakage** from new brace nesting in the
   rewritten `coderecord`/`__newindex`. Low impact (readability only); follow the
   style contract.
7. **Doc drift** — five+ doc files describe the dual scheme as a feature; leaving
   them stale misleads the next engineer. Mitigate: §6 doc checklist.

---

## 8. Decisions (resolved by the owner)

1. **Convert `_mod` to a `Udata`?** **YES** — and go further: remove the
   Lua-facing module table so `require` returns the `Udata` (§2.3). This is the
   owner's stated goal, not optional uniformity.
2. **Field index base** for records: landed **0-based** (`uv[0..N-1]`, no
   reserved slot) — Lua never sees the indices, so the reserved `uv[0]` was pure
   waste. The module `Udata` is **also 0-based**: `nextupvalue` hands out the
   counter then post-increments (`NUPVALS` = slot count), the importer's
   member-slot reconstruction starts at 0 to match, and the old `uv[0]` (the
   removed module table's slot) is gone. (The first cut shipped 1-based with a
   reserved `uv[0]` for a minimal diff; the 0-based rebase followed immediately.)
3. **`Type.Nominal` ctype** flips `CClosure*` → `Udata*`; accepted, along with the
   full ABI fan-out (every record-typed param/return/local/`self`/out-param, and
   every `_mod`/`_init` signature) and the **ABI marker advance** it forces.
4. **Empty-record / zero-field layout:** with 0-based fields, `nuvalue = #fields`,
   so an empty record is a 0-user-value `Udata` (`luaS_newudata(L, sizeof(void*),
   0)`); the tag still lives in `getudatamem` and the metatable on the udata, so
   the machinery stays uniform.
5. **Timing:** the anon-functions branch is merged to `master` and the `_fn` ABI
   is frozen, so only one ABI moves now. ✔

### Implementation order actually used

1. Records → `Udata` (ctype + leaf accessors + `coderecord` + field access +
   record `__index`/`__newindex` + bound-method self), *while `_mod` is still a
   CClosure that records read their metatable from* — so this and step 2 are
   landed together (they share the `_mod`/record entanglement and the ABI bump).
2. `_mod` → `Udata` (signatures, `_init`, every `->upvalue[i]`→`->uv[i].uv`,
   barriers forward→back, `_init` return type, recovery accessors,
   `titan_pushmodule`).
3. Remove the module table; build the member-map metatable on the `Udata`;
   `require`/postamble return the `Udata`; per-record namespace uv slots.
4. Advance the ABI marker, update docs, add GC-stress tests, run the full suite.

---

### Appendix: the one-line essence

```
record value      :  CClosure(uv[0]=udata, uv[1..N]=fields)  +  Udata(tag, uv[0]=closure, metatable)
                  ─────────────────────────────────────────────────────────────────────────────────►
                     Udata(tag, metatable, uv[0..N-1]=fields)          // one object; ctype Udata*; back barriers; 0-based

_mod (module)     :  CClosure(uv[0]=Lua table, uv[1..]=vars/fnclosures/imports/metas)  + Lua returns the table
                  ─────────────────────────────────────────────────────────────────────────────────────────►
                     Udata(uv[0..]=vars/fnclosures/imports/metas/recnamespaces, metatable)   // 0-based, no reserved slot
                     // one object; ctype Udata*; back barriers; require returns THIS; no separate module table

function value    :  CClosure(uv[0]=_mod, uv[1]=tag, uv[2]=native, uv[3+]=captures)   // UNCHANGED — must stay callable
                     // uv[0] now holds the module Udata value (read with uvalue, not clCvalue)
```
