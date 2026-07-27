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
— the initializer still runs. Parameters (`_param_<name>`) rely on the
*caller's* anchoring and get a `_paramslot_<name>` only if assigned to
inside the function (`param._assigned`). Module variables live in `_mod`
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
form is simpler: there is no count — `_foridx += _forstep` and the loop
breaks once `_foridx` passes `_forlimit` in the step's direction.

The body tail gets the same allocation-gated `luaC_checkGC(L);` as
`while`. `codereturn` evaluates the checker's adjusted return list once,
stores fixed returns 2..n through `*_outparam_<i>`, fills a requested
flexible-output descriptor when the function has one, resets
`L->top.p = _base`, and returns the first fixed value in C (or `void` when
there is no fixed result). See [Calls](#calls).

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
not truthiness: for option, `value`, and raw C `TValue` controls it is
`ttisnil(&ctrl)`, and for nullable C pointer controls it is `ctrl == NULL`,
so `false` keeps iterating.

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

`codearray` consumes the checker's `_positional_adjustment`. It evaluates
every retained scalar and open-tail producer in lexical order, asks
`titan_array_new` for an exact initial capacity, and fills only positive
array-part slots. The backing and proxy are independently rooted across
allocation; collectable element stores barrier the backing Table.

The final logical length is the highest non-nil produced position, so trailing
nils do not inflate `#array`. A final open producer (`...`, a flexible-return
call, or a contextual call through `value`) contributes its actual run after
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
/* checkandget(elem-type, result, _s, loc) follows */
```

The inline path returns nil for every index below 1, beyond capacity, or in a
hole. It never consults the hash part. The mixed-domain converter then
validates the element; nested Array reads additionally accept either an
internal backing Table or a canonical proxy written by Lua.

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

## Maps

Map access dispatches on the **static key type**; the key is boxed into
an anchored temp slot and passed as a `TValue*`.

### Read (`codeindexmap` + `get_table_key`)

**String** keys test for the interned-short-string fast path; **integer**
keys call `luaH_getint(t, ivalue(k), ...)`; **float** keys are first
normalized with `luaV_tointeger(k, &ik, F2Ieq)` so `m[1.0]` and `m[1]`
hit the same entry; anything else takes plain `luaH_get`. All variants
normalize an empty tag to nil and finish with the same `checkandget` (or
option-nil shortcut) as arrays. Real output for `m: {string:integer}`:

```c
_tmp_2 = _param_k;
setsvalue(L, _tmp_2_slot, _tmp_2);         /* anchored key slot */
TValue _s_v;
lu_byte _s_tag;
if (ttypetag(_tmp_2_slot) == LUA_VSHRSTR) {
    _s_tag = luaH_getshortstr(_t, tsvalue(_tmp_2_slot), &_s_v);
} else {
    _s_tag = luaH_get(_t, _tmp_2_slot, &_s_v);
}
if (tagisempty(_s_tag)) {
    setnilvalue(&_s_v);
}
```

A value Lua smuggled in with the wrong type surfaces here as a deferred
run-time error, e.g. `expected integer but found string`.

### Write (`set_table_entry`) and constructor (`codemap`)

Writes box raw-visible values with `setboxed` into a local `TValue _vv`, then:
integer keys use `luaH_setint`; float keys normalize via
`luaV_tointeger(..., F2Ieq)` then `luaH_setint` or `luaH_set`; all other
keys — including strings; the read-side short-string split has no write
analogue — take the generic path:

```c
luaH_set(L, _t, _tmp_2_slot, &_vv);
invalidateTMcache(_t);
```

The `invalidateTMcache` on generic stores mirrors Lua's own API split: a
raw store under a string key could shadow a metamethod name, so
`lua_rawset` flushes the table's metamethod-absence cache while
`lua_rawseti` does not, and the coder reproduces exactly that. The
caller emits `luaC_barrierback(L, obj2gco(_t), &_vv);` when the map's
*value* type is GC-able. `codemap` builds constructors like arrays —
`luaH_new` anchored immediately, every key and value in its own anchored
slot, `set_table_entry` per entry plus the back barrier. An all-positional
constructor is accepted only for an exact integer key type; it consumes the
same `_positional_adjustment` as Array construction, pre-sizes the ordinary
table's array part, and stores positions 1 through N. `#m` for such a Map uses
`luaH_getn`, so holed Maps retain Lua's unspecified valid-border semantics.

## Records

### Construction (`coderecord`)

One allocation (real output for `Point.new`; the layout's rationale is in
[values and the GC](values-and-gc.md)):

```c
{
    Udata* _ud = luaS_newudata(L, 0, 2);              /* #fields user values, no raw payload */
    setuvalue(L, _tmp_1_slot, _ud);                   /* anchor the udata FIRST */
    _ud->metatable = hvalue(&_mod->uv[1].uv);         /* this metatable IS the type identity */
    /* per field i: setobj2t(L, &(_ud->uv[i].uv), $SLOT), then
       luaC_barrierback(L, obj2gco(_ud), &(_ud->uv[i].uv)) for GC-able
       field types */
}
```

The udata is anchored *before* any field expression can collect (no
second allocation to order, and no closure↔udata cross-link to install).
fields are 0-based at `uv[0..N-1]` (no reserved slot); field initializers
each go through an anchored temp and a `setobj2t` into `&(_ud->uv[i].uv)`
plus a **back** barrier (the owner is a userdata) for GC-able field types.

### Field access

A read is an indexed load from the udata — no hashing, no metatable:
`return fltvalue(&((__self__)->uv[0].uv));`. A write is the user-value
store plus a *back* barrier (`Udata` owner, like table stores, unlike
closure stores):

```c
Udata *_recobj = _param_p;
TValue *_fieldslot = &(_recobj->uv[0].uv);
setfltvalue(_fieldslot, _param_v);
/* + luaC_barrierback(L, obj2gco(_recobj), _fieldslot); for GC-able fields */
```

### Method and static calls

Within a module, `p:getx()` is a **direct C call** under the native
convention, self passed as the raw `Udata*` right after `_mod` (and the
`_fn` slot):

```c
return test_Point_getx_titanmethod(L, _mod, NULL, _param_p);
```

(naming: `<mangled-fqtn>_<name>_titanmethod` / `..._titanstatic`).
Cross-module calls are still direct C calls — the caller holds the
target module's `Udata` in one of its own user values and passes
`uvalue(&_mod->uv[i].uv)` as the callee's `_mod`; dependencies selected from
source or a static provider become `extern` prototypes, while dependencies
selected from a DSO become `static` **function pointers** stitched in `_init`
from the dlopened library:

```c
static lua_Integer (*dep_mk_titan)(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer);
/* in _init: */
dep_mk_titan = titan_cast_func(lua_Integer (*)(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer),
                               loadsym(L, dep_handle, "dep_mk_titan"));
```

Records cross the Lua boundary unchanged — the value Titan computes with
*is* the Udata Lua sees (`setboxed`); coming back, `checkandget`
verifies the record metatable/type identity and uses the udata directly
([Lua interop internals](lua-interop-internals.md)).

## Strings

**Literals** compile to `luaS_new(L, "<escaped>")` (`makestring`,
escaping by `c_string_literal`); short strings are interned, so repeated
evaluation of a short literal yields the same `TString*`. Without a
`target` the result is anchored in a temp slot; with one, the local's
own slot refresh anchors it.

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

`LUAI_MAXSHORTLEN` is 40 in this Lua build; at or below it the result
must be interned (`luaS_newlstr`), above it `luaS_createlngstrobj`
allocates up front so the copy happens exactly once.

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
once. **Equality on dynamic values**: when both operands are
`TValue`-represented (`value` or options), `==`/`~=` compile to
`luaV_rawequalobj(&l, &r)` and its negation. **`and`/`or`** specialize on static truthiness: boolean
operands become C `&&`/`||`; statically truthy/falsy sides short-circuit
at compile time. In the general case the left operand is first
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

## Casts: every `ExpCast` variant

The checker materializes every implicit coercion as an `Ast.ExpCast`
([the type checker](checker.md)), so this dispatch in `codeexp` is the
complete inventory of conversions:

1. **Cast of an array/map index expression** is folded into the read:
   the `VarBracket`'s `_type` is temporarily replaced by the cast target
   so the read's `checkandget` lands directly in the target type.
2. **`value` → T**: copy the `TValue` to a temp, then
   `checkandget(typ, dst, &src, loc)`. The errors are the boundary
   shapes: `%s:%d:%d: type error, expected %s but found %s` (Lua's tag
   name for primitives, the registry-mapped record name for foreign
   records), and for integer targets fed a fractional float,
   `%s:%d:%d: type error, number '%f' has no integer representation`.
3. **T → `value`**: `setboxed` into a `TValue` temp — records remain their
   Udata and Arrays become their canonical proxy. No new slot: the source
   stays anchored where it was.
4. **integer → float**: `((lua_Number)<exp>)`.
5. **anything → boolean**: `toboolean(type, exp)`.
6. **float → integer**: an exactness check with `lua_Number` temps —
   `$TMP2 = l_floor($TMP1);` then
   `if ($TMP1 != $TMP2) { luaL_error(L, "type error at line %d, number '%f' has no integer representation", ...); } else { lua_numbertointeger($TMP2, &$TMP3); }`
   — so an integer coerced from `2.0` is `2` and one coerced from `2.5`
   raises at run time. This variant is only ever checker-synthesized:
   an explicit `2.0 as integer` is a *compile-time* error (`cannot cast
   'float' to 'integer'`), because the checker's cast rule demands the
   pair also be `types.compatible`, which float/integer is not.
7. **integer/float → string**: `_integer2str` / `_float2str` (see
   [Strings](#strings)), anchored unless built into a target.
8. **nil → `t?`**: `setnilvalue(&$TMP);`.
9. **t → `t?`** (wrap): `setslot(base-type, &$TMP, exp)` — box the
   native value into a `TValue`.
10. **`t?` → t** (unwrap):
    `if(TITAN_UNLIKELY(ttisnil(&$CEXP))) { luaL_error(L, "%s:%d:%d: type error, expected %s but found nil", ...); } else { $GETSLOT }`,
    so a nil reaching any unwrap position raises a clean
    `expected <T> but found nil` at run time.
11. **→ foreign pointer**: `nativetoforeignexp` first performs any required
    boundary conversion, followed by the target C cast. A `value` source uses
    `checkandget`; in particular, Lua-internal `Udata *` accepts full userdata
    or nil and rejects lightuserdata. Ordinary already-native pointer
    conversions can remain a plain `(($CTYPE)($CEXP))` cast
    ([FFI internals](ffi-internals.md)).

## Type tests: `ExpIs`

`codeexp` lowers an `Ast.ExpIs` through `coder._codeis`. It first
`materialize`s the operand, which both evaluates it exactly once and keeps a
GC value rooted while a metatable or Array-proxy predicate runs. It then emits
the non-raising predicate corresponding to the admitted written `ExpCast`:

By-value C struct and union operands use the existing aggregate temporary
path instead of the generic scalar temporary path. This preserves exact-once
evaluation without generating an invalid scalar initializer for a C
aggregate.

* A boxed `value` target mirrors `checkandget`: integer tests accept an integer
  tag or an exact integral float that passes `lua_numbertointeger`; float tests
  accept either numeric tag; primitive/Map tests use `ttis*`; Array, nominal
  record, and owned-C tests compare the same exact metatable; C pointer targets
  distinguish ordinary lightuserdata from the Lua-internal `Udata *`
  full-userdata case.
* A target `Option(T)` first accepts nil, then mirrors `checkandset(T, ...)`.
  This distinction matters for boolean: direct `value as boolean` uses
  truthiness and therefore `value is boolean` is total, while
  `value as boolean?` requires nil or an actual boolean and
  `value is boolean?` uses that strict tag predicate. Function slots remain
  deliberately unchecked.
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

`codecall` implements the caller's half of the native calling convention
([overview](codegen-overview.md)). Argument marshaling is minimal: each
argument's preliminary statements run in lexical order, then only the
checker's delivered fixed prefix and accepted input tail are passed — already
native, already anchored at their sources; there is no per-call pushing.
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
and publishes an actual count. GC-able fixed results and open-run elements are
stored into reserved caller stack slots before the next allocation — the
callee never pushes native results and the raw descriptor is not a root.

Real output for
`local a, b = two()` where `two(): (integer, string)`, caller then
callee:

```c
TString* _tmp_1 = 0;                /* paired with _tmp_1_slot */
lua_Integer _tmp_2 = 0;
_tmp_2 = test_two_titan(L, _mod, NULL, &_tmp_1);
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

Every run-time error in generated code is a `luaL_error(L, ...)` emitted
by `codethrow` or its callers. Two prefix conventions coexist:

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

Boolean and `value` targets never throw — every Lua value converts.
Flexible input/output runs instead report their explicit
`TITAN_VARARG_MAX` overflow errors. The module metatable raises
`member '%s' does not exist in Titan module '%s'`. Whenever an
error crosses a Lua entry wrapper, the runtime's `errorhandler` records
a C-level backtrace retrievable via `titan.backtrace()`
([error handling](../language/error-handling.md)).
