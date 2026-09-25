# Code generator: constructs

This chapter walks construct by construct through how `coder.lua`
translates Titan into C, with trimmed excerpts of **real compiler
output** (`$VAR` placeholders appear only where a template is quoted).
The translation-unit anatomy, calling convention and module protocol are
in the [overview](codegen-overview.md); value representation, stack-slot
anchoring and write barriers in [values and the GC](values-and-gc.md).

Two contracts shape every generator: **statement generators** take
`(ctx, node)` and return a string of C statements, while **expression
generators** return *two* strings — preliminary C statements plus a C
expression (`""` statements for trivial expressions). And every value
has the **dual representation**: a C variable of its unboxed native type
plus, when GC-able, a paired Lua stack slot (`s2v(_base + k)`) that
keeps it visible to the collector; code computes with the C variable and
refreshes the slot after every store. `codeexp(ctx, node, iscondition,
target)` also threads `target` — a `VarName` lvalue's `_decl`, letting
eligible constructors build directly into the lvalue's `_cvar`/`_slot`.
Dense Array constructors deliberately ignore that optimization and first
anchor their backing in a scanned temporary slot, because an owning module or
record slot is not necessarily remembered until its caller emits the final
barrier. The dispatch also threads `iscondition`, which no generator
currently consumes: truth conversion
happens in `codeif`, `codewhile`/`coderepeat`, and the `as boolean` cast,
via `toboolean`.

## Locals and assignment

`Ast.StatDecl` (in `codestat`) gives a used local a C variable
`_local_<name>_<n>` (the `localname` suffix keeps shadowing valid C)
and, for GC-able types, a shadow slot refreshed at declaration and at
every later assignment:

```c
TString* _local_t_1;
TValue *_localslot_t_2 = s2v(_base + 0);
_local_t_1 = _param_s;
/* update slot */
setsvalue(L, _localslot_t_2, _local_t_1);
```

A local the checker marked unused generates only `$CSTATS ((void)$CEXP);`
— the initializer still runs. An unassigned/unspilled parameter
(`_param_<name>`) remains only its C formal and relies on the input's existing
allocation/result/semantic/VM provenance; native calls create no argument root.
A `_paramslot_<name>` is a real local/spill home used only when the parameter is
assigned or must survive setjmp recovery. Module variables live in `_mod`
user values: reads are `getslot` from `&_mod->uv[i].uv`, writes add
`luaC_barrierback(L, obj2gco(_mod), <slot>);` for GC-able types (a
userdata owner, back barrier); imported-module variables go through the
import's `Udata` (`uvalue(&_mod->uv[MOD].uv)->uv[VAR].uv`) with the same
barrier.

`codesingleassignment` and `codemultiassignment` share
`_materialize_assignment_lvalue`, so assignment lowering separates target
preparation from right-hand evaluation and from the eventual store.

**Multiple assignment is three-phase** (`codemultiassignment`):

1. `_materialize_assignment_lvalue` walks the targets in lexical left-hand
   order. Simple local and module-variable targets need no preparation.
   Effectful record receivers, Array/Map containers and indices or keys, and C
   field/index operands are evaluated exactly once and frozen in temporaries.
   GC owners and boxed Map keys are retained in scanned slots. The resulting
   descriptor identifies the eventual store but does not mutate it or perform
   its target-specific store validation.
2. `_codeadjustedfixed` walks the checker's complete lexical right-hand
   expression list, materializes every delivered value, and forces every
   explicit surplus expression only for effect. GC-bearing values use ordinary
   shadow slots, so an allocating later expression cannot collect an earlier
   result.
3. `codeassignment` consumes the prepared descriptors from left to right,
   performing each target's validation and mutation. An earlier store
   therefore remains committed if a later Array index, C bounds check, or
   other store condition raises.

The right-hand temporaries still give `x, y = y, x` swap semantics:

```c
_tmp_1 = _local_y_1;
_tmp_2 = _local_x_1;
_local_x_1 = _tmp_1;
_local_y_1 = _tmp_2;
```

`codesingleassignment` invokes the same generic preparer for its sole target,
then materializes the right-hand side, then calls `codeassignment`. Effectful
record receivers, Array/Map containers and indices or keys, and C field/index
operands therefore precede the right-hand side in both single and multiple
assignment; final target validation and mutation follow it.

C target preparation is recursive. `_prepare_c_base` freezes a loaded pointer,
retains a `COwned` userdata in a scanned slot while using its payload pointer,
decays an addressable C array into an element pointer plus its length, or keeps
an addressable struct/union subobject through a synthesized pointer rather than
copying it. `_prepare_c_storage` walks the nested field/index chain needed to
obtain that address. The final target's NULL or bounds check remains deferred
to `codeassignment`, but a check needed to traverse an intermediate base runs
during target preparation: code cannot safely form the next subobject address
without it. The narrow `_prepare_c_loaded_value` exception may copy a
by-value aggregate temporary only to extract and freeze a pointer field or
pointer-array element; the eventual store targets that pointer's persistent
pointee, not the temporary aggregate.

## Control flow: `if`, `while`, `repeat`

The recurring problem is **condition statement-hoisting**: a Titan
condition may need preliminary C statements (a table read, a call) that
cannot live in a C `while(...)` head.

`codeif` builds a recursive `if / else if` chain, putting each arm's
preliminary statements in an enclosing block and wrapping the condition
with `toboolean(type, cexp)`, so option- and `value`-typed conditions
become real C truth tests (`!l_isfalse(...)`, `!ttisnil(...)`).
`codewhile` and `coderepeat` wrap their conditions with the same
`toboolean`, so a numeric condition is always truthy (matching Lua, where
`0`/`0.0` are true) and option- or `value`-typed conditions test for nil
rather than emitting a bare `TValue`.

`codewhile` emits a plain `while($CEXP) { $CBLK $CHECKGC }` when the
condition needs no statements; otherwise it hoists them into the body:

```c
while(1) {
    $CSTATS
    if(!($CEXP)) {
        break;
    }
    $CBLK
    $CHECKGC
}
```

`coderepeat` is the same trick with the test at the bottom:
`while(1) { $CBLK $CSTATS if($CEXP) { break; } $CHECKGC }`.

`$CHECKGC` is `luaC_checkGC(L);` **only when the condition plus body
created stack slots** — the generators diff `ctx.allocations` (bumped by
every `newslot`) across the body. Pure-arithmetic loops carry no GC
polling; allocating loops poll once per iteration, since native code
never passes through `luaD_call` and would otherwise starve the collector.

## The numeric `for`

`codefor` follows Lua 5.5's own `forprep`/`forloop`/`floatforloop`
(`lvm.c`). It precomputes `_forstart`, `_forlimit` and `_forstep` once,
raises a clean `'for' step is zero` run-time error on a zero step, and
then drives the integer loop with an **unsigned iteration count**
computed up front rather than re-comparing the control variable against
the limit each turn. The count is the number of remaining steps, so the
loop runs exactly that many times and an integer loop near
`mininteger`/`maxinteger` terminates instead of overflowing into a
non-terminating loop. The body's visible control variable is a **fresh
copy** taken from a separate internal index (`_foridx`) each iteration,
so it is independent of the iteration and effectively read-only — the
checker rejects an assignment to it as `cannot assign to 'for' control
variable`, matching Lua 5.4+.

Real output for `for i = 1, n, 2` (integer form):

```c
{
    lua_Integer _forstart = 1;
    lua_Integer _forlimit = _param_n;
    lua_Integer _forstep = 2;
    if (_forstep == 0) {
        luaL_error(L, "test.titan:1:1: 'for' step is zero");
    }
    if (_forstep > 0 ? (_forstart <= _forlimit) : (_forstart >= _forlimit)) {
        lua_Unsigned _forcount = (_forstep > 0)
            ? (l_castS2U(_forlimit) - l_castS2U(_forstart)) / l_castS2U(_forstep)
            : (l_castS2U(_forstart) - l_castS2U(_forlimit)) / (l_castS2U(-(_forstep + 1)) + 1u);
        lua_Integer _foridx = _forstart;
        while (1) {
            lua_Integer _local_i = _foridx;
            ...
            if (_forcount == 0) {
                break;
            }
            _forcount--;
            _foridx = l_castU2S(l_castS2U(_foridx) + l_castS2U(_forstep));
        }
    }
}
```

The unsigned count and `l_castS2U`/`l_castU2S` stepping keep the step
arithmetic out of C signed-overflow undefined behavior. The visible
`_local_i` is only declared when the body actually reads it. The float
form is simpler: there is no count —
`_foridx = luai_numadd(L, _foridx, _forstep)` uses Lua's configured numeric
addition hook, and the loop breaks once `_foridx` passes `_forlimit` in the
step's direction.

The body tail gets the same allocation-gated `luaC_checkGC(L);` as
`while`. `codereturn` evaluates the checker's adjusted return list once,
stores fixed returns 2..n through `foreign *_outparam_<i>`, fills a requested
flexible-output descriptor when the function has one, resets
`L->top.p = _base`, and returns the first fixed value in C (or `void` when
there is no fixed result). See [Calls](#calls).

An [immediately called anonymous function](immediate-functions.md) instead has
an inline result destination: its return supplies outer holders and exits its
own logical function scope, preserving the caller's stack frame and cleanup.

## The generic `for ... in`

`codeforin` consumes the checker's elaborated `Ast.StatForIn`; it does no
iterator type reasoning of its own. The four tuple expressions are evaluated
once into hidden C locals named `_forin_*`, and any GC-able tuple value gets
a Lua stack slot immediately. Iterator return values live in a second set of
hidden locals, also slotted when GC-able, so a string/record returned by the
iterator survives body allocations before it is copied into the visible loop
variable.

The loop body is generated as:

```c
$INITCALL
while (1) {
    if ($ISNIL) {
        break;
    }
    $VISIBLE_DECLS
    $BODY
    $NEXTCALL
    luaC_checkGC(L);
    _base = restorestack(L, _base_off);
}
```

`$INITCALL` and `$NEXTCALL` are synthesized by the checker. Function-typed
iterators are ordinary function-value calls emitted by `codevaluecall`, so
an exact Titan iterator can take the native fast path and a Lua callable can
take the generic Lua-stack path. C function-pointer iterators carry
`_c_pointer_call` and use `codecfunctionptrcall` instead. The nil test is
not truthiness: native foreign numeric Options test their presence flag;
ordinary Options, `value`, and raw C `TValue` controls use `ttisnil(&ctrl)`;
nullable C pointer controls use `ctrl == NULL`. Thus `false` keeps iterating.

When the close slot is present, `codeforin` wraps the run node in a
synthetic `Ast.StatTry` whose `finally` block calls the hidden close
function with zero arguments or with the hidden state value, depending on
the checked close type. That puts the initial iterator call, all body
executions and all update calls inside the protected region, so close runs
on normal exhaustion, `break`, `return`, and raised errors. The generic loop
frame is opened outside that synthetic try, which lets `break` route through
the same pending-action machinery as a user-written `finally`. A close raise
therefore overrides the pending action in the same way any `finally` raise
does. When the close slot originated as `value`, the call inside `finally` is
guarded by an exact `ttisnil` test of the hidden close `TValue`. Nil makes the
finalizer a no-op and preserves the pending action; every non-nil value still
uses the ordinary function-value call path, so its call or error has the same
precedence as any other close. Statically function-typed closers remain
unconditional.

## Arrays

Array lowering operates on the internal backing `Table *`, never on the
Lua-visible proxy. The complete representation, ownership, boxing, and
authoritative-length protocol is in [Dense Arrays](dense-arrays.md).

### Constructor (`codearray`)

`codearray` consumes the checker's `_positional_adjustment`. It evaluates every
retained scalar and open-tail producer in lexical order, asks the module-local
writer inventory for the constructor's final element type, and chooses the
qualified constructor from the checked Array context. A mutable constructor
passes the cached writer to `titan_array_new`; a const constructor calls
`titan_const_array_new`, whose second proxy user value is nil. Both receive the
exact initial capacity and an active traced result slot, which the stack-neutral
runtime helper uses to root and publish the backing/proxy cycle without a
public Lua stack operation. They then fill only positive array-part slots;
collectable element stores barrier the backing Table.

The final logical length is the highest non-nil produced position, so trailing
nils do not inflate `#array`. A final open producer (`...`, a flexible-return
call, a contextual call through `value`, or a
[spread expression](spread-expressions.md)) contributes its actual run after
the fixed prefix. The same adjustment/lowering machinery is shared with a
positional exact integer-keyed Map, whose destination is instead an ordinary
Table.

### Read (`codeindexarray`)

```c
Table *_t = _param_t;
lua_Integer _k = _param_i;
TValue _av = {0};
if (_k < 1) {
    setnilvalue(&_av);
} else {
    lua_Unsigned _slot = l_castS2U(_k) - 1u;
    if (_slot < _t->asize) {
        arr2obj(_t, cast_uint(_slot), &_av);
        if (tagisempty(ttypetag(&_av)))
            setnilvalue(&_av);
    } else {
        setnilvalue(&_av);
    }
}
const TValue *_s = &_av;
/* strict GuardPlan(elem-type) lowering follows */
```

The inline path returns nil for every index below 1, beyond capacity, or in a
hole. It never consults the hash part. The mixed-domain converter then
consumes the static element's strict `GuardPlan`: numeric and boolean tags are
not coerced, Option recurses on its present arm, and C/nominal/container
categories have explicit guards. Nested Array reads additionally accept either
an internal backing Table or the exact qualified canonical proxy written by
Lua. Runtime recovery recognizes either Array tag as a proxy before enforcing
the target qualifier; it never infers mutability from a structurally similar
userdata.

### Write (`codeassignment`, VarBracket on an array)

```c
TValue _vv;
/* represent _tmp_1 for an internal typed Array element in _vv */
if (_k < 1) {
    luaL_error(L, "array index must be positive");
}
if (l_castS2U(_k) - 1u < _t->asize) {
    obj2arr(_t, cast_uint(l_castS2U(_k) - 1u), &_vv);
    /* update titan_array_length(_t), including tail backscan */
} else if (!ttisnil(&_vv)) {
    titan_array_resize(L, _t, titan_array_growth(L, l_castS2U(_k)));
    obj2arr(_t, cast_uint(l_castS2U(_k) - 1u), &_vv);
    titan_array_set_length(_t, l_castS2U(_k));
}
```

Writes require a positive index. An in-capacity store is direct; a non-nil
write beyond capacity grows to the smallest power of two strictly greater
than the logical index, while nil beyond capacity is a no-op. Unsupported
growth raises `array index too large`; it never falls back to a hash entry.
Every store updates the highest-present logical length, including a backward
scan when deleting the tail, and barriers collectable elements against the
backing Table. `#arr` reads the guarded authoritative `lenhint`; it never calls
`luaH_getn`.

Const Array assignment is rejected by the checker and cannot reach this
lowering. This is the mutable typed Titan path and bypasses the proxy writer.
The shared Lua `__newindex` path instead treats nil as deletion, or calls the
construction writer's checker-provided `DynamicCoercionPlan` before any growth
or store. Writer failure leaves length, capacity, and contents unchanged.

## Maps

Map access dispatches on the **static key type**; the key is boxed into an
anchored temporary stack slot and passed as a `TValue *`. Reads and assignments
keep that specialized inline work as the common path. They use the VM finish
helpers only after the relevant metatable check says a metamethod may exist;
they do not lower the whole operation to `lua_gettable` or `lua_settable`.

### Read (`codeindexmap` + `get_table_key`)

**String** keys test for the interned-short-string fast path; **integer** keys
call `luaH_getint(t, ivalue(k), ...)`; **float** keys are first normalized with
`luaV_tointeger(k, &ik, F2Ieq)` so `m[1.0]` and `m[1]` hit the same entry;
anything else takes plain `luaH_get`. These raw getters write into the already
rooted key slot and leave it untouched on a miss, allowing that one real stack
slot to become the result slot just as it does in Lua's `lua_gettable` path.
The generated shape for a string-keyed Map is:

```c
lu_byte _s_tag;
if (ttypetag(_key_slot) == LUA_VSHRSTR) {
    _s_tag = luaH_getshortstr(_t, tsvalue(_key_slot), _key_slot);
} else {
    _s_tag = luaH_get(_t, _key_slot, _key_slot);
}
if (tagisempty(_s_tag)) {
    if (TITAN_LIKELY(checknoTM(_t->metatable, TM_INDEX))) {
        setnilvalue(_key_slot);
    } else {
        TValue _table;
        sethvalue(L, &_table, _t);
        _s_tag = luaV_finishget(L, &_table, _key_slot,
                               _key_stack, _s_tag);
        _base = restorestack(L, _base_off);
    }
}
_s = _key_slot;
```

`checknoTM` covers both no metatable and the cached absence of `__index`; that
likely branch preserves the old miss-to-nil behavior without a VM call. When
`__index` may exist, the original `Table *` is boxed for `luaV_finishget`. Its
`StkId` result argument is the reserved key stack entry, never a local
`TValue *`; this lets the VM implement function, table, and recursively
metamethod-aware chains using its own loop bound. Because that call can grow or
relocate the Lua stack, generated code restores `_base` from `_base_off` before
using any stack-derived pointer.

The caller then points `_s` at the result slot and applies the unchanged strict
`GuardPlan` (or option-nil shortcut). A wrong value therefore surfaces as the
same deferred run-time error, e.g. `expected integer but found string`, whether
it came from a raw entry or `__index`. Maps carry no write provenance channel,
and an integral float returned by a metamethod does not become an integer on a
typed Map read.

### Assignment (`set_table_entry`) and constructor (`codemap`)

Assignments box raw-visible values with `setboxed` into a local `TValue _vv`.
The likely `checknoTM(t->metatable, TM_NEWINDEX)` branch uses the original raw
setter verbatim: integer keys call `luaH_setint`; float keys normalize via
`luaV_tointeger(..., F2Ieq)` and use `luaH_setint` or `luaH_set`; all other keys
— including strings, because the read-side short-string split has no write
analogue — call `luaH_set` and invalidate the metamethod cache:

```c
if (TITAN_LIKELY(checknoTM(_t->metatable, TM_NEWINDEX))) {
    luaH_set(L, _t, _key_slot, &_vv);
    invalidateTMcache(_t);
} else {
    int _hres = luaH_pset(_t, _key_slot, &_vv);
    if (_hres != HOK) {
        TValue _table;
        sethvalue(L, &_table, _t);
        luaV_finishset(L, &_table, _key_slot, &_vv, _hres);
        _base = restorestack(L, _base_off);
    }
}
```

When `__newindex` may exist, the coder first uses Lua's partial-set protocol.
Integer and integral-float keys use `luaH_fastseti`, not `luaH_psetint`, because
the key may name an array-part slot; other keys use `luaH_pset`. `HOK` means an
existing entry was updated in place, correctly bypassing `__newindex`. Any
other result describes the unresolved location and is passed, with the boxed
original table, to `luaV_finishset`, which implements the function/table/value
metamethod chain, its loop bound, insertion, cache invalidation, and barriers
for the actual target. The call can relocate the stack, so `_base` is restored
immediately afterward. The Map and key were already frozen and rooted by
`_materialize_assignment_lvalue` before the right-hand side was evaluated;
dispatch therefore preserves Map, key, RHS, store order and cannot retain a
stack-derived pointer across the VM call.

The caller still emits its existing
`luaC_barrierback(L, obj2gco(_t), &_vv);` after the helper for a GC-able Map
value. That is the original table's barrier for a raw or `HOK` update;
`luaV_finishset` supplies the required barrier for the actual target when the
assignment is redirected through a chain. The generic raw setter's
`invalidateTMcache` also remains: a store under a string key can shadow a
metamethod name.

`codemap` is deliberately separate. It allocates a fresh `luaH_new` table with
no metatable, anchors it immediately, evaluates every key and value into its
own anchored slot, then uses `set_table_entry_raw` plus the caller's back
barrier. Constructors therefore do not pay a metatable check or partial-set
cost. An all-positional constructor is accepted only for an exact integer key
type; it consumes the same `_positional_adjustment` as Array construction,
pre-sizes the ordinary table's array part, and stores positions 1 through N.

### Length (`code_map_length`)

The checker admits `#m` only for an exact integer-keyed Map, preserving the
surface result type `integer`. `code_map_length` materializes and roots the Map
operand once. The likely `checknoTM(map->metatable, TM_LEN)` branch calls
`l_castU2S(luaH_getn(L, map))` inline, so a no-metatable or cached-no-`__len`
Map retains Lua's ordinary valid-border semantics without a public `lua_len`
call.

When `__len` may exist, the coder boxes that same `Table *`, reserves a real
Lua `StkId` result slot, and calls
`luaV_objlen(L, result_stack, &boxed_map)`. This delegates callable metamethod
dispatch and Lua result production to the VM. The call can relocate the stack,
so `_base` is restored immediately and the result slot address is recomputed
from its saved offset. The coder then requires `ttisinteger(result)` before
using `ivalue(result)`; an integral float or any other tag raises
`expected integer tag but found ...` rather than crossing a dynamic conversion
boundary. Arrays keep their separate authoritative `lenhint` path.

### Equality (`codebinaryop`)

Metamethod-aware equality is selected from the checker's original
`ComparisonPlan.left` and `.right` types, not merely from the operands' final C
representations. This distinction matters because comparison adjustment boxes
the Map side of Map/`value`, while an unrelated `value`/`value` comparison has
the same pair of `TValue` carriers and must remain raw.

Map/Map evaluates and materializes the left operand, then the right, exactly
once. Pointer identity resolves equality immediately. For distinct tables,
paired `checknoTM(..., TM_EQ)` tests resolve false inline when both sides have
no metatable or cached absence of `__eq`. Only the remaining
possible-metamethod case boxes both tables and calls
`luaV_equalobj(L, &left, &right)`. The VM keeps primitive identity first,
selects the left `__eq` or falls back to the right one, calls callable
metamethod values, and converts the result with Lua truthiness.

Map/`value` and `value`/Map likewise evaluate left to right and begin with
`luaV_rawequalobj`. A raw-unequal pair continues only when both run-time values
are tables and `checknoTM` does not prove `__eq` absent from both; that narrow
case calls `luaV_equalobj`. A non-table dynamic value therefore cannot enter
table metamethod dispatch. Plain `value`/`value`, Arrays, Functions, nominal
values, and Options retain their previous comparison paths.

Each metamethod-aware branch stores one boolean result. The potentially
calling `luaV_equalobj` path restores `_base` before later stack-root use, and
`~=` negates the already materialized result rather than redispatching or
reevaluating either operand.

## Records

### Construction and field access

`nominallayout.lua` assigns physical slots independently of logical field
indices. GC-bearing fields occupy dense user values, with public slots before
private slots. Non-GC fields occupy generated C payload members; fixed
aggregates and arrays are copied there, and eligible direct fresh allocations
can occupy checked, aligned trailing regions. The new userdata is rooted before
field initialization can allocate. Traced stores retain the ordinary userdata
back barrier.

`coder/nominal.lua` lowers reads, writes, and boxing from that plan. A native
scalar read uses its payload member directly. An embedded aggregate or array
read projects a borrowed interior pointer. Writes complete the checker-owned
conversion before changing storage; only traced writes need a GC barrier.
Ordinary typed access remains direct and requires neither hashing nor Lua
member lookup. See [Native nominal storage](nominal-storage.md) for the public
prefix, allocation, and separate-compilation contracts.

### Method and static calls

Within a module, `p:getx()` is a **direct C call** under the native
convention, self passed as the raw `Udata*` right after `_mod` (and the
`_fn` slot):

```c
return test_\u2133_Point_\u2131_getx_titanmethod(L, _mod, NULL, _param_p);
```

(naming: `<mangled-module>_\u2133_<owner>_\u2131_<name>_titanmethod` /
`..._titanstatic`).
Cross-module calls are still direct C calls — the caller holds the
target module's `Udata` in one of its own user values and passes
`uvalue(&_mod->uv[i].uv)` as the callee's `_mod`; dependencies selected from
source or a static provider become `extern` prototypes, while dependencies
selected from a DSO become `static` **function pointers** stitched in `_init`
from the dlopened library:

```c
static lua_Integer (*dep_\u2133_mk_titan)(lua_State *L, Udata *_mod,
                                                CClosure *_fn, lua_Integer);
/* in _init: */
dep_\u2133_mk_titan = titan_cast_func(
    lua_Integer (*)(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer),
    loadsym(L, dep_handle, "dep_\u2133_mk_titan"));
```

Records cross the Lua boundary unchanged — the value Titan computes with
*is* the Udata Lua sees (`setboxed`); coming back, `checkandget`
verifies the record metatable/type identity and uses the udata directly
([Lua interop internals](lua-interop-internals.md)).

An Interface call is the deliberate exception to symbol-directed method
dispatch. The checker records the declaration-order method slot; generated
code anchors the wrapper, loads and casts that payload entry, and calls it with
the concrete-owner module and receiver from wrapper user values 0 and 1.
Exact slots point at the concrete method; adjusted slots point at a private
adapter with the Interface signature. Bound references capture the wrapper in
the ordinary branded-closure shape. See [Interfaces](interfaces.md).

## Unions and `case`

`coder._codeunioninit` allocates the selected variant's payload size and dense
traced-slot count. Every variant payload starts with an actual shared tag-header
subobject; the absolute tag is native data, never a user value. Empty variants
therefore need no traced slots. Parts use the same native/traced classification
as record fields. An Array part retains its internal `Table *` backing in its
assigned UV slot, with a userdata back barrier.

`coder._codecase` evaluates and roots the scrutinee once, reads its tag header,
and emits a switch containing only `case TAG: goto ARM;` entries. Arm bodies
are labeled blocks outside the switch and end at one case-end label, preserving
ordinary `break`, `catch`, `finally`, and `defer` behavior. Bindings use the
selected variant's physical plan; aggregates and arrays project borrowed
pointers, while numeric Options keep their exact native value. Logical part
indices remain independent of both payload members and UV indices. See
[Native nominal storage](nominal-storage.md).

Statement-list generation stops after `break` or the first statement whose
checker decoration has `_always_returns = true`. The coder therefore consumes
one shared reachability result for direct `return`/`raise` and for compound
blocks, `if`, `try`, `case`, and a proven non-fallthrough literal-true `while`;
it does not try to rediscover termination from only the immediate AST tag. This
boundary is necessary because the checker does not visit a dead tail after a
non-fallthrough statement, so those nodes have no type/declaration decorations
to generate safely.

## Strings

**Literals** compile to `luaS_new(L, "<escaped>")` (`makestring`,
escaping by `c_string_literal`); short strings are interned, so repeated
evaluation of a short literal yields the same `TString*`. Without a
`target` the result is anchored in a temp slot; with one, the local's
own slot refresh anchors it. `c_string_literal` emits a dollar byte as the C
octal escape `\044`: generated fragments are recursively template-rendered,
so this preserves the user byte without letting a following identifier become
another `$NAME` substitution.

**Concatenation** (`Ast.ExpConcat`) flattens n-ary `..` chains into one
operation and never calls `luaV_concat`: the total length is precomputed,
then a short result is assembled in a C stack buffer and interned, while
a long result allocates the string first and is filled in place. Real
output for `a .. b .. "x"`, trimmed:

```c
size_t _len = 0;
size_t _tl = 0;
TString *_str1 = _param_a;
size_t _len1 = tsslen(_str1);
if (TITAN_UNLIKELY(
        _len1 >= MAX_SIZE - sizeof(TString) - _len))
    luaL_error(L, "string length overflow");
_len += _len1;
/* ... _str2, _str3 likewise; literal anchored in its own slot ... */
if(_len <= LUAI_MAXSHORTLEN) {
    char _buff[LUAI_MAXSHORTLEN];
    memcpy(_buff + _tl, getstr(_str1), _len1 * sizeof(char));
    /* ... */
    _tmp_1 = luaS_newlstr(L, _buff, _len);
} else {
    _tmp_1 = luaS_createlngstrobj(L, _len);
    char *_buff = getstr(_tmp_1);
    /* same memcpy sequence into the string's own payload */
}
setsvalue(L, _tmp_1_slot, _tmp_1);
```

Each operand is checked before adding its length, using Lua's own maximum
string-object bound. This both prevents `size_t` wraparound and ensures that
the short-buffer decision is made from the exact total length.
`LUAI_MAXSHORTLEN` is 40 in this Lua build; at or below it the result must be
interned (`luaS_newlstr`), above it `luaS_createlngstrobj` allocates up front
so the copy happens exactly once.

**Number-to-string** coercions call the `inline static` helpers in
`titan-runtime/titan.h`: `_integer2str(L, i)` (`lua_integer2str` then
`luaS_newlstr`) and `_float2str(L, f)` (`luaO_tostringbuff`), so the
formatting is bit-for-bit Lua's — integral floats print with `.0`.

## Operators with inlined Lua semantics

Most operators on native types are the plain C operator —
`"(" .. lhs .. op .. rhs .. ")"` — but where Lua and C disagree, the
algorithm is inlined and shaped so constant operands let the C compiler
delete the branches.

**Shifts** (`generate_binop_shift`). The rationale comment in `coder.lua`:

> Most of the time, the shift amount should be a constant, which will
> allow the C compiler to eliminate all of these branches as dead code
> and generate code that is just as good as a raw C bitshift without the
> extra Lua semantics.
>
> For the dynamic case, we gain a bit of performance (~20%) compared to
> the algorithm in luaV_shiftl by reordering the branches to put the
> common case (shift amount is a small positive integer) under only one
> level of branching and with a TITAN_LIKELY annotation.

(The ~20% is the comment's claim; no benchmark lives in the repository.)
Real output for `x << y` (`>>` swaps the operator pair):

```c
if (TITAN_LIKELY(l_castS2U(_param_y) < TITAN_LUAINTEGER_NBITS)) {
    _tmp_1 = intop(<<, _param_x, _param_y);
} else {
    if (l_castS2U(-_param_y) < TITAN_LUAINTEGER_NBITS) {
        _tmp_1 = intop(>>, _param_x, -_param_y);
    } else {
        _tmp_1 = 0;
    }
}
```

**Integer `//`** (`generate_binop_idiv_int`; comment: "Lua/Titan integer
division rounds to negative infinity instead of towards zero. We inline
luaV_div here to give the C compiler more optimization opportunities"):

```c
if (l_castS2U(_param_b) + 1u <= 1u) {      /* n == 0 or n == -1 */
    if (_param_b == 0){
        luaL_error(L, "error at line %d, divide by zero", 41);
    } else {
        _tmp_1 = intop(-, 0, _param_a);    /* m // -1 == -m, overflow-safe */
    }
} else {
    _tmp_1 = _param_a / _param_b;
    if ((_param_a ^ _param_b) < 0 && _param_a % _param_b != 0) {
        _tmp_1 -= 1;                       /* fix C's round-toward-zero */
    }
}
```

**Integer `%`** (`generate_binop_mod_int`, preserving Lua's invariant
`m == n*(m//n) + m%n`): the same branch-free `n == 0 or -1` test, raising
`error at line %d, % by zero` for zero, yielding `0` for `-1`, otherwise
correcting C's remainder sign with
`if (r != 0 && (m ^ n) < 0) { r += n; }`. Float `//` is `floor(x / y)`,
and float `%` (`generate_binop_mod_flt`) is faithful to Lua's
`luai_nummod`: `r = fmod(m, n)` with a sign correction
(`if ((r > 0) ? n < 0 : (r < 0 && n > 0)) { r += n; }`) so the result
takes the sign of the divisor, as floored division requires.

**`^`** always produces a float and follows Lua's `luai_numpow`:
exponent `2` is special-cased as `b * b` (where `b` is the base hoisted
into a float temp), every other exponent uses `pow(b, e)` — both
operands are materialized into float temps first, so each is evaluated
once. **Equality on ordinary dynamic values**: when both operands are
`TValue`-represented (`value` or options), `==`/`~=` normally compile to
`luaV_rawequalobj(&l, &r)` and its negation. The narrowly selected
[Map/`value` path](#equality-codebinaryop) adds table `__eq` after a failed raw
check; `value`/`value` remains raw. **`and`/`or`** specialize on static truthiness.
For a boolean result the checker wraps non-boolean operands with an
`_operator_conversion` whose operation is `truthiness`; `not` uses the same
operation. The coder consumes this annotation before ordinary cast dispatch,
materializes the operand in its own representation, and calls `toboolean`.
This keeps `value` truthiness separate from the strict tag guard selected by
an ordinary `value`-to-`boolean` assignment. Generic annotation erasure retains
the operator decision, including when an optional type parameter erases to
`value`.

Boolean-result operators emit explicit C branches with all right-operand
evaluation inside the selected branch. Statically truthy/falsy value-returning
sides short-circuit at compile time. In the general case the left operand is first
**materialized into a temp of its own type** and the truthiness test
runs through `toboolean(lhs-type, temp)` rather than taking the address
of a raw left-hand expression — so the test works for a boolean C value,
a comparison rvalue, an option, or a `value` alike, and the operand is
evaluated exactly once (it may be a non-lvalue such as a direct call).
This is what makes the `cond and a or b` ternary idiom, long all-boolean
`and`/`or` chains, and a `<call> or default` (e.g. `return find(xs,v) or
0`) compile. The `t? or default` shape unwraps the option on the truthy
side — the generated form of the `t[i] or v` idiom — and a `value`-typed
`or` tests the materialized temp with `l_isfalse`.

**Integer arithmetic wraps like Lua, not C.** Integer `+ - *` and unary
`-` emit `intop(...)` — `intop(+, x, y)`, `intop(*, x, y)`,
`intop(-, 0, x)` for negation — which does the operation in the unsigned
domain (`l_castU2S(l_castS2U(v1) op l_castS2U(v2))`, `lvm.h`), giving
defined two's-complement wraparound instead of C's signed-overflow
undefined behavior. So `math.maxinteger + 1` is `math.mininteger` and
unary minus of `math.mininteger` is itself, with no UB regardless of
optimizer or `-fwrapv`. Binary `~` (Lua's bitwise *exclusive-or*)
compiles to `intop(^, x, y)` — C's binary xor is `^`, while Titan's `^`
is exponentiation. Shifts negate the amount with `intop(-, 0, y)` so a
shift amount of `math.mininteger` is well-defined rather than overflowing
under `-y`. Integer `//`, `%` and the shifts now materialize their
operands into temps first, so a side-effecting operand (`f() // g()`,
`x << g()`) is evaluated exactly once even though the template references
each operand several times.

**Float literals** are emitted with `%.17g` — full round-trip precision
for every finite `double`, where the old `%f` truncated to six fractional
digits. A literal that overflows to `+inf` (e.g. `1e400`) becomes
`HUGE_VAL` (and `-inf` becomes `(-HUGE_VAL)`), since C has no `inf`
literal.

**Mixed integer/float comparisons** (`< <= > >= == ~=` with one
`integer` and one `float` operand) are inlined as calls to the
static-inline helpers in `titan-runtime/titan.h` —
`titan_lt_intfloat`/`titan_le_intfloat`/`titan_lt_floatint`/`titan_le_floatint`
and `titan_eq_intfloat` — chosen by the *static* operand types, so the
operands stay unboxed native scalars with no `TValue` round-trip. These
mirror Lua's `LTintfloat`/`LEintfloat`/`luaV_equalobj` int-vs-float
paths: they compare the mathematical values with no precision loss, so a
large `integer` is never rounded to a float before the test (`> >=` are
emitted as the swapped `< <=` helper, `~=` as the negated `==`). An
`int`/`int` or `float`/`float` comparison stays a plain C `<`/`<=`/`==`.

## Casts and checker plans

The checker materializes representation-changing fixed operations as
annotated `Ast.ExpCast` nodes and retains same-representation/open operations
on their consumers ([the type checker](checker.md)). `codeexp` dispatches on
the stored plan rather than treating every unequal pair as a scalar cast:

1. **Array/Map index projection** uses the read's strict `GuardPlan`; a
   written cast is not folded into this path merely because both share an
   `Ast.ExpCast` shape.
2. **Implicit `value` → T** consumes a gradual projection and performs the
   strict tag/shape guard. Numeric cross-tag conversion and truthiness are not
   available.
3. **Written `value as T`** consumes the embedded
   `DynamicCoercionPlan`: integral in-range floats may produce integers,
   integers may produce floats, booleans use truthiness, and Option recurses.
   The same plan's non-raising form implements `is`. For an Interface leaf,
   `checkandget` accepts the exact wrapper or raw-looks up a
   compiler-witnessed entry on a bare full userdata's metatable and calls it
   for one result. Implicit/strict Interface guards use that same leaf; no
   checker plan changes.
4. **T → `value`** uses `setboxed` into a `TValue` temp — records and unions
   remain their Udata and Arrays become their canonical proxy. No new slot:
   the source stays anchored where it was.
5. **integer → float** is `((lua_Number)<exp>)`.
6. **anything → boolean** uses the direct truthiness coercion selected by the
   checker, distinct from a strict gradual guard.
7. **float → integer** performs the exactness/range check with
   `lua_Number` temps and `lua_numbertointeger`. Both automatic and written
   numeric conversions have explicit plans; neither is consistency.
8. **integer/float → string** uses `_integer2str` / `_float2str` (see
   [Strings](#strings)), anchored unless built into a target.
9. **nil → `t?`** emits `setnilvalue`.
10. **t → `t?`** boxes the present value with the plan's `option_wrap`.
11. **`t?` → t** checks nil before lowering `option_force`'s inner plan, so
    absence raises a clean `expected <T> but found nil`.
12. **→ foreign pointer** lets `nativetoforeignexp` lower the exact C
    conversion plan. A `value` source needs the separately written unsafe
    raw-pointer operation; it is never an implicit gradual projection.
    Lua-internal `Udata *` accepts full userdata or nil and rejects
    lightuserdata. Ordinary already-native pointer conversions can remain a
    plain C cast ([FFI internals](ffi-internals.md)).
13. **mutable Array → const Array** consumes the `array_freeze` plan. Its
    default lowering calls `titan_array_shallow_copy`; only a checker-authored
    `_linear_array_freeze` annotation may call `titan_array_freeze` and retag
    the original proxy in place. The coder performs no liveness analysis.

## Type tests: `ExpIs`

`codeexp` lowers an `Ast.ExpIs` through `coder._codeis`. It first
`materialize`s the operand, which both evaluates it exactly once and keeps a
GC value rooted while a metatable or Array-proxy predicate runs. It then emits
the non-raising predicate corresponding to the admitted written `ExpCast`:

By-value C struct and union operands use the existing aggregate temporary
path instead of the generic scalar temporary path. This preserves exact-once
evaluation without generating an invalid scalar initializer for a C
aggregate.

* A written `value is T` backed by a `DynamicCoercionPlan`: integer tests
  accept an integer tag or an exact integral float that passes
  `lua_numbertointeger`; float tests accept either numeric tag;
  primitive/Map tests use `ttis*`; Array, nominal record/union, and owned-C
  tests compare the expected metatable. An Interface test accepts that exact
  wrapper or a non-nil raw entry under the target Interface metatable on a bare
  full userdata's metatable. It never calls or validates the entry and remains
  allocation-free.
* A target `Option(T)` first accepts nil, then recursively applies the same
  dynamic plan for `T`. Thus direct `value as boolean` and present
  `value as boolean?` both use truthiness, while nil is preserved;
  `value is boolean?` reports the same total acceptance. Function slots remain
  deliberately unchecked until invocation.
* A raw C-pointer target has no `DynamicCoercionPlan`. The separately
  authorized written unsafe `value is CPointer(T)` predicate accepts the broad
  lightuserdata/nil category without claiming to prove the pointee type;
  `Udata *` is the specialized full-userdata/nil case.
* Exact `T? is T` is `!ttisnil`, and C `char *`/`void * is string` is a
  non-NULL test.
* Identity and every other total admitted cast emit true after consuming the
  materialized operand.

No target value is constructed and no cast-mismatch `luaL_error` path is
emitted. Errors from evaluating the operand are outside the predicate and
therefore still propagate.

`Ast.ExpAdjust` (truncating a multi-value expression to one value, the
`(f())` form) is a pass-through to the inner expression.

## Calls

A direct anonymous-literal callee is lowered as an
[inline scoped block](immediate-functions.md), sharing the argument plans and
finite/open demand below but omitting closure allocation and callable dispatch.

`codecall` implements the caller's half of the native calling convention
([overview](codegen-overview.md)). Argument marshaling is minimal: preliminary
statements run in lexical order, effect-ordered values are frozen only in C, and
then the checker's delivered fixed prefix and accepted input tail are passed.
There is no tracing-only native-input publication or per-call pushing.
Explicit surplus arguments still run but are discarded. If the source call
supplied too few fixed arguments, the checker has already appended
`Ast.ExpNil` expressions and inserted the ordinary coercions, so code
generation treats them exactly like written `nil` arguments.

For fixed multiple returns the caller allocates one temp per visible extra
return (with a shadow slot iff GC-able) and passes the ABI out-parameter
addresses. The temp names are recorded in `node._extras` so the
checker-synthesized `Ast.ExpExtra` nodes read them directly. The callable's
declared ABI shape remains separate from this consumer-visible projection: a
discarded result may still need a hidden ABI holder on an exact call, but it is
never published as a live expression value.

For a flexible producer `_flex_call_buffer` appends a typed caller-owned
descriptor and `_flexwant` budget to the call. A finite demand gets a
right-sized buffer; an open demand gets the bounded `TITAN_VARARG_MAX` backing
and publishes an actual count. After return and rebasing, every live GC-bearing
fixed result and open-run element is immediately stored into its reserved caller
slot/range—the callee never pushes native results and the raw descriptor is not
a root.

Real output for
`local a, b = two()` where `two(): (integer, string)`, caller then
callee:

```c
TString* _tmp_1 = 0;                /* paired with _tmp_1_slot */
lua_Integer _tmp_2 = 0;
_tmp_2 = test_\u2133_two_titan(L, _mod, NULL, &_tmp_1);
setsvalue(L, _tmp_1_slot, _tmp_1);  /* re-anchor the GC-able result */
```

```c
_tmp_1 = luaS_new(L, "a");
setsvalue(L, _tmp_1_slot, _tmp_1);
*_outparam_2 = _tmp_1;
L->top.p = _base;
return 1;
```

A call used as a statement has `_discard_results`/`_voidok`; its effects run
but none of its results become consumer-visible. Calls *from Lua* go through
the generated entry wrappers, which ignore surplus arguments for fixed
functions (or collect them for input-variadic functions), pad missing fixed
arguments with nil, check argument types, honor Lua's requested flexible-result
count, and install the error handler — see
[Lua interop internals](lua-interop-internals.md).

## Run-time errors: `codethrow` and message conventions

Generated run-time errors ultimately use `luaL_error(L, ...)`, either through
`codethrow` or through a boundary/runtime-specific check. The following are
the two most common source-location formats; they are conventions, not an
exhaustive inventory of every generated diagnostic:

* **`%s:%d:%d:` — `filename:line:col`** (the `.titan` path given to the
  checker). Used by all `checkandget`/`checkandset` sites: boundary
  argument checks, `value` casts, array/map element checks, record tag
  mismatches (`expected test.Rec but found test.Point`), the
  option unwrap above, and the record `__index`/`__newindex`
  field-not-found errors (`field '%s' not found in record '%s'`).
* **`at line %d` — line only.** Used by the inlined arithmetic and the
  float→integer coercion: `error at line %d, divide by zero`,
  `error at line %d, % by zero` (Lua 5.5's `pushvfstring` passes the
  unknown `%` sequence through literally), and
  `type error at line %d, number '%f' has no integer representation`.

At a genuine Lua/dynamic boundary, boolean truthiness and copying an existing
Lua `TValue` into `value` are total. Strict implicit `value -> boolean`
projection, typed Array/Map reads, and branded Titan-generic observations
instead require the exact boolean tag and may raise. Injecting a native C
scalar into `value` may also raise when the value does not fit Titan's
`TValue` carrier. Flexible input/output runs report their explicit
`TITAN_VARARG_MAX` overflow errors. The module metatable raises
`member '%s' does not exist in Titan module '%s'`. Whenever an
error crosses a Lua entry wrapper, the runtime's `errorhandler` records
a C-level backtrace retrievable via `titan.backtrace()`
([error handling](../language/error-handling.md)).
