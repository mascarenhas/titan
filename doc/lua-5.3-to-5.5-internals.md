# Lua 5.3 → 5.5 internal differences that affect Titan

> This is the historical Lua 5.3.5-to-5.5.0 internal-difference catalogue. For
> the Lua 5.5.1 and Titan ABI 0.21 follow-up, see the
> [Lua 5.5.1 Update Audit](implementation/lua-5.5.1-update.md).

Titan's generated C code and its runtime support library compile against
Lua's *internal* headers (`lobject.h`, `ltable.h`, `lvm.h`, `lgc.h`,
`ldo.h`, `lstring.h`, ...), not just the public API. This document records
every internal difference between Lua 5.3.5 and Lua 5.5.0 that affected the
compiler, found by diffing the two source trees against an inventory of all
identifiers Titan uses. It is the reference for why the migration changes
in [lua-5.5-migration.md](lua-5.5-migration.md) look the way they do.

## 1. Type tags: variants renamed, booleans lost their payload

* All internal *variant* tag constants were renamed from `LUA_T*` to
  `LUA_V*`, built with `makevariant` (lobject.h): `LUA_TNUMINT` →
  `LUA_VNUMINT`, `LUA_TNUMFLT` → `LUA_VNUMFLT`, `LUA_TSHRSTR` →
  `LUA_VSHRSTR`, `LUA_TLNGSTR` → `LUA_VLNGSTR`, `LUA_TCCL` → `LUA_VCCL`,
  etc. The public `LUA_T*` basic types from `lua.h` are unchanged.
* The tag accessor `ttype(o)` changed meaning: in 5.3 it returned
  tag+variant; in 5.5 it returns only the basic type (what 5.3 called
  `ttnov(o)`, which no longer exists). The old meaning is now
  `ttypetag(o)`. Consequence: `lua_typename(L, ttnov(x))` becomes
  `lua_typename(L, ttype(x))`, and variant dispatch like
  `ttype(k) == LUA_TSHRSTR` becomes `ttypetag(k) == LUA_VSHRSTR`.
* Booleans no longer carry a payload: the `Value` union lost its `int b`
  field, and truth is encoded in the tag itself (`LUA_VFALSE` /
  `LUA_VTRUE`). `bvalue(o)` and `setbvalue(obj,x)` are **gone**; the 5.5
  replacements are `ttistrue(o)`/`ttisfalse(o)` and the single-argument
  setters `setbtvalue(obj)`/`setbfvalue(obj)`. Any `switch` on a value's
  type tag must now have *two* boolean cases.
* Nil gained internal variants (`LUA_VEMPTY`, `LUA_VABSTKEY`,
  `LUA_VNOTABLE`) used to mark empty table slots and absent keys.
  `ttisnil()` matches all of them; `tagisempty(tag)` / `isempty(v)` /
  `isabstkey(v)` are the table-slot tests. 5.5's `setobj` asserts (in
  debug builds) that a non-strict nil is never blind-copied, so code must
  not copy a raw "empty" slot value around.

## 2. The stack: `StackValue`, `StkId`, `s2v()`, and `.p` unions

The single most invasive change. In 5.3 the Lua stack was an array of
`TValue` and `StkId` was `TValue*`. In 5.5:

* Stack entries are `union StackValue { TValue val; ...tbclist... }`,
  `StkId` is `StackValue*`, and a stack slot is viewed as a `TValue*`
  through `s2v(o)` (= `&(o)->val`). `sizeof(StackValue)` is not guaranteed
  equal to `sizeof(TValue)`, so pointer arithmetic over stack slots must
  use `StkId`, never `TValue*`.
* `L->top`, `L->stack`, `L->stack_last`, `ci->top` and `ci->func` are now
  `StkIdRel` unions (`{ StkId p; ptrdiff_t offset; }`); the live pointer
  is the `.p` member. Every `L->top` in 5.3-era code becomes `L->top.p`,
  every `L->ci->func + i` becomes `s2v(L->ci->func.p + i)`, etc.
* `savestack`/`restorestack` keep their call syntax but operate on the
  union fields; `restorestack` now returns `StkId`.
* The 2s-suffixed store macros (`setobj2s`, `sethvalue2s`, ...) now take a
  `StkId` destination and apply `s2v` internally. `setclCvalue` has no
  `2s` variant, so pushing a closure manually requires an explicit
  `s2v(L->top.p)`.

## 3. Tables: the array part has no `TValue` slots anymore

5.5 redesigned the table array part into an *inverted* `Value` array plus
a separate byte array of tags, with a length hint in between (see the
diagram in 5.5's `ltable.h`). Consequences:

* `t->sizearray` was renamed/retyped to `t->asize` (5.4's `alimit`
  scheme is gone again in 5.5).
* `&t->array[i]` is no longer a valid expression, conceptually or
  literally (`t->array` is `Value*`, points *between* values and tags).
  All array-part access goes through macros: `getArrTag(t,k)` /
  `getArrVal(t,k)`, `arr2obj(h,k,val)` (array → TValue),
  `obj2arr(h,k,val)` (TValue → array), and the tag-precomputed
  `farr2val`/`fval2arr`. Indices are 0-based C indices.
* The "obtain a writable `TValue*` slot, store later" code-generation
  strategy is dead for the array part. It survives only for hash-part
  nodes, closure upvalues, and stack slots.

The raw access API changed calling convention entirely:

* Getters return a tag and copy the value out:
  `lu_byte luaH_get/getshortstr/getstr/getint(Table*, key, TValue *res)`.
  **`*res` is left untouched when the key is absent** — callers must
  check `tagisempty(tag)` and `setnilvalue` the holder themselves.
  `luaH_fastgeti(t,k,res,tag)` inlines the array fast path.
* `luaO_nilobject` no longer exists; the internal sentinel is a private
  `absentkey` (tag `LUA_VABSTKEY`). Pointer-comparing a result against a
  nil sentinel is dead as a pattern. The only exported slot-returning get
  is `luaH_Hgetshortstr` (for metamethod lookups).
* `luaH_newkey` is now file-static and value-taking. Raw stores go
  through `void luaH_set(L, t, key, value)` / `luaH_setint(L, t, ikey,
  value)`, or the pre-set protocol (`luaH_pset*` returning `HOK`/`HNOTFOUND`/
  node encodings + `luaH_finishset`). The *caller* is responsible for the
  GC write barrier; new-key insertion barriers the key internally.
  After raw string-key inserts the TM cache must be invalidated
  (`invalidateTMcache(t)`, which needs `ltm.h` for `maskflags`).
* `luaH_getn` now takes the `lua_State*`: `luaH_getn(L, t)`.
* `Node` keys are no longer stored as a `TValue`: `gkey(n)` is gone,
  replaced by `keytt(n)`/`keyval(n)` accessors. Code that walked the hash
  chain comparing keys with `luaV_rawequalobj(gkey(n), key)` (like the
  copy of `getgeneric` Titan's runtime carried) cannot be ported
  mechanically; 5.5's own `getgeneric`/`equalkey` are the model — or use
  the exported `luaH_get` family instead.
* `luaV_fastget`/`luaV_fastset` macros changed shape accordingly (tag/
  hres-based, no more slot pointers; the barrier moved out of fastset
  into `luaV_finishfastset`). `luaV_tointeger`'s mode parameter is now
  the `F2Imod` enum (`F2Ieq` replaces the literal `0`).

## 4. Strings and userdata

* `TString`: `getstr`/`tsslen` survive with the same usage (the
  discrimination is now via the sign of `shrlen`; 5.5 also supports
  external strings). `luaS_new`, `luaS_newlstr`, `luaS_createlngstrobj`,
  `luaS_hashlongstr` are unchanged. `luaS_eqlngstr` was renamed
  `luaS_eqstr`. Writing into a fresh `luaS_createlngstrobj` through
  `getstr` still works.
* `Udata` was redesigned (in 5.4, kept in 5.5): the 5.3 fields `ttuv_`
  and `union Value user_` are gone. A userdata now has `unsigned short
  nuvalue` and an array of full-TValue user values `UValue uv[1]`, and
  `luaS_newudata` takes the user-value count:
  `luaS_newudata(L, size, nuvalue)`. A `nuvalue == 0` userdata has *no*
  uv array and the GC will not traverse user values of it — anything
  stashed there is invisible to the collector. `getudatamem` still works
  (the payload now sits after the uv array). `lua_newuserdata` at the API
  level is `lua_newuserdatauv`.

## 5. Garbage collector

* The 5.5 standalone interpreter switches to **generational mode at
  startup** (`lua.c`: `lua_gc(L, LUA_GCGEN)`), while `luaL_newstate`
  alone leaves incremental mode. Titan `.so` modules loaded into stock
  `lua` therefore run generational; Titan standalone executables run
  incremental. Generated code must be barrier-correct for both.
* Under generational GC, missing write barriers stop being a narrow
  mid-cycle race and become near-deterministic corruption: old objects
  are simply not traversed by minor collections, so a new object stored
  into an old one without a barrier is swept while still referenced.
* `luaC_barrier` (forward, for C-closure upvalue stores) keeps its 5.3
  call shape. `luaC_barrierback_` now takes `GCObject*` instead of
  `Table*`, so backward-barrier call sites must wrap the table:
  `luaC_barrierback(L, obj2gco(t), v)`.
* `luaC_upvalbarrier` and the refcounted `UpVal` of 5.3 are gone (UpVals
  are ordinary GC objects since 5.4). Not used by Titan.
* Emergency collections (`luaC_fullgc` on allocation failure) exist in
  both versions and can run inside *any* allocating internal call. In
  generational mode an emergency collection ages every survivor to
  old+black (`sweep2old`), which is what makes "allocate A, anchor it,
  allocate B, store B into A without a barrier" a real use-after-free in
  5.5 where the same sequence happened to be safe in 5.3 (5.3's full GC
  left survivors white).

## 6. Number formatting and conversions

* The `lua_number2str` macro is gone from `luaconf.h`. Float-to-string
  conversion is the internal `unsigned luaO_tostringbuff(const TValue*,
  char *buff)` with a `LUA_N2SBUFFSZ` (64) byte buffer. Its behavior
  differs from a raw `%.14g`: it uses `%.15g`, retries with `%.17g` when
  the result does not read back equal, and **appends `.0`** when the
  output looks like an integer. `lua_integer2str` is unchanged.
* `lua_numbertointeger` moved from `luaconf.h` to `llimits.h`
  (definition unchanged).
* `MAXNUMBER2STR` is private to 5.5's `lobject.c`; the public buffer-size
  constant is `LUA_N2SBUFFSZ` in `lua.h`.

## 7. Auxiliary library behavior

* `luaL_Buffer` is stack-resident from `luaL_buffinit` on: a placeholder
  (later the box userdata) sits on the stack and **must be on top**
  whenever the buffer grows or `luaL_pushresult` runs. The 5.3 pattern of
  interleaving unrelated `lua_push*` calls between buffer operations
  worked only because 5.3's buffer touched the stack lazily (at 8 KB
  spill); under 5.5 it corrupts the box bookkeeping and crashes inside
  `resizebox`. Code must finish all other pushes before `luaL_buffinit`
  (this bit Titan's `errorhandler`).
* `luaL_checkversion` (run by `luaL_newlib`) now checks 505, giving a
  clean failure mode when a 5.3-built module is loaded into a 5.5 host.

## 8. Header/macro housekeeping

* `llimits.h` defines a single-argument `cast_func(p)`; Titan's
  two-argument `cast_func(t,p)` macro collided and was renamed
  `titan_cast_func`.
* `invalidateTMcache` lives in `ltable.h` but expands to `maskflags`
  from `ltm.h`, so generated code that invalidates the TM cache must
  include `ltm.h`.
* `lua_Unsigned`, `l_castS2U`/`l_castU2S`, `intop`, `l_floor`,
  `LUAI_MAXSHORTLEN`, `luaV_rawequalobj`, `luaV_equalobj`, `luaC_checkGC`,
  `luaF_newCclosure` and the whole `CClosure` layout are unchanged.

## 9. Changes to Lua-the-language that affect the compiler's own code

The compiler itself is written in Lua and now runs on a Lua 5.5 host:

* **For-loop control variables are read-only** (`<const>`) in 5.5.
  Assigning to one is a compile error. Two places in the compiler did
  this (`c-parser/cpp.lua`, `titan-compiler/pretty.lua`).
* `global` is a reserved word in 5.5 (checked: no identifier in the
  compiler or in serialized module types uses it in a breaking position;
  `types.serialize` emits constructor calls with quoted strings, not
  bare-identifier table keys).
* Decimal integer literals that overflow are read as *floats* by 5.4+
  (5.3 wrapped them). Titan's lexer converts number literals with the
  host's `tonumber`, so an overflowing decimal Titan literal now lexes as
  a float instead of a wrapped integer — consistent with the 5.5 host
  language Titan now targets.
* `__call` chains are limited (not hit), `utf8.char` accepts up to
  0x7FFFFFFF (the lexer's `\u{...}` range follows the host), and the
  5.4+ library changes (`io.lines`, `math.random`, bitwise coercions)
  were audited with no impact on the compiler sources.
