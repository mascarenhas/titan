#ifndef TITAN_H
#define TITAN_H

#include <float.h>
#include <math.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#include "llimits.h"
#include "lobject.h"
#include "lstring.h"
#include "ltable.h"
#include "luaconf.h"
#include "lvm.h"

/*
** Small trusted Lua-internal value bridges live with their FFI declarations.
** Includes shared macros and inline functions between the C FFI and the Titan
** runtime
*/
#include "titan/ffi.h"

/*
** ===========================================================================
** VENDORED FROM Lua 5.5.1 src/ldo.c lines 61-109 (keep VERBATIM; re-sync on
** every Lua upgrade). The struct must stay byte-compatible with the linked
** liblua.a: lstate.h only forward-declares `struct lua_longjmp`, so providing
** the full definition here is conflict-free, and the generated module C uses it
** to install an inline setjmp boundary for catch/finally without calling into
** Lua's (private) luaD_rawrunprotected with a thunk.
**
** Titan generates C and builds Lua with longjmp (the `make lua` build), so the
** C++-exception arm of the upstream ladder is intentionally OUT OF SCOPE here:
** we only vendor the _setjmp/setjmp arms and add a statement-form TITAN_SETJMP
** selected by the SAME #ifdef ladder.
** ===========================================================================
*/

/* --- BEGIN verbatim from lua-5.5.1/src/ldo.c:61-65 --- */

/* chained list of long jump buffers */
typedef struct lua_longjmp {
  struct lua_longjmp *previous;
  jmp_buf b;
  volatile TStatus status; /* error code */
} lua_longjmp;

/* --- END verbatim --- */

/*
** Statement-form setjmp selector, mirroring the upstream LUAI_THROW/LUAI_TRY
** #ifdef ladder (lua-5.5.1/src/ldo.c:74-107) but expressed as a value usable in
** an `if (TITAN_SETJMP(buf) == 0) { ... }` boundary (the upstream LUAI_TRY is
** function-form and takes a Pfunc; we cannot use it for inline straight-line
* C).
** The same selection (_setjmp on POSIX, setjmp otherwise) keeps the buffer
** read/written by the same routine the linked liblua.a uses for LUAI_THROW.
*/
#if defined(LUA_USE_POSIX)
#define TITAN_SETJMP(buf) _setjmp(buf)
#else
#define TITAN_SETJMP(buf) setjmp(buf)
#endif

/* TITAN_ABI_VERSION is the monotonic compiled-module compatibility integer,
   encoded as a canonical decimal string in module metadata. TITAN_VERSION is
   the compiler and standard-library semantic version.
   TITAN_LIBRARY_VERSION is its major/minor component and owns installed
   library paths plus the versioned TITAN_PATH override. */
#define TITAN_ABI_VERSION "2"
#define TITAN_VERSION "0.6.0"
#define TITAN_LIBRARY_VERSION "0.6"
#define TITAN_LIBRARY_VERSION_SUFFIX "_0_6"
#define TITAN_PATH_VAR "TITAN_PATH"
#define TITAN_PATH_SEP "/"
#define TITAN_ROOT_DEFAULT "/usr/local"
#define TITAN_LUA_CPATH_SUFFIX "/lib/lua/5.5/?.so"
#define TITAN_ROOT_KEY "9efb91a8-4a1b-4bdb-aa6b-b84d9ed1dd77"
#define TITAN_PATH_KEY "ec10e486-d8fd-11e7-87f4-e7e9581a929c"
#define TITAN_LIBS_KEY "ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"
#define TITAN_BT_STATE_KEY "a222927d-0e7b-4f7a-93d9-1a6ce7111a5c"

/* Registry sub-table mapping a native Titan C symbol name (the mangled name the
** coder emits for a function/method/static/anonymous native entry) -> the
** qualified Titan source name to display in a trace ("<module>.<func>",
** "<module>.<record>:<method>", "<module>.<record>.<static>", or "anonymous
** function at <file>.titan:<linedefined>"). Each module's _init lazily creates
** the sub-table (multiple modules contribute) and populates it for every native
** function it generates. errorhandler looks each native frame's DWARF symbol up
** here and shows the qualified name when found, falling back to the raw symbol.
** A runtime/_init addition only: it does not by itself change the compiled
** module ABI. */
#define TITAN_NAMES_KEY "a7c4e2f0-1d6b-4e3a-9c5f-8b2d7e0a4f16"

#define TITAN_LUAINTEGER_NBITS cast_int(sizeof(lua_Integer) * CHAR_BIT)

/*
** Dense Titan Arrays use an ordinary Lua Table as their exact/native backing
** object, but reserve its hash key 0 for the canonical Lua-visible proxy.
** Keep this limit textually aligned with Lua 5.5's private MAXASIZE formula:
** every positive Array index must fit in the table's array part, with no hash
** fallback.
*/
#define TITAN_ARRAY_METATABLE "Titan array metatable"
#define TITAN_CONST_ARRAY_METATABLE "Titan const array metatable"
#define TITAN_ARRAY_MAX_CAPACITY                                               \
  (((1u << (l_numbits(int) - 1)) < (MAX_SIZET / (sizeof(Value) + 1)))          \
       ? (1u << (l_numbits(int) - 1))                                          \
       : cast_uint(MAX_SIZET / (sizeof(Value) + 1)))

/*
** One copied entry in an Interface wrapper's opaque payload. Generated code
** converts concrete native method pointers to this storage type and back
** through titan_cast_func; the payload never contains data pointers.
*/
typedef void (*TitanInterfaceMethod)(void);

/* Variadic-parameter descriptors. One per `ctype` so `args` has the exact
** element pointer type. `n_args` is the TOTAL backing count; `start` is NOT a
** struct field — it travels as a separate `int _start` native parameter, so a
** callee's logical view is `args[start .. n_args-1]` and forwarding never
** mutates a shared descriptor. Static call sites point these descriptors at
** typed C-stack arrays; runtime-sized forwarding points them at anchored
** userdata storage. */
typedef struct {
  lu_byte n_args;
  lua_Integer *args;
} TitanVargInteger;
typedef struct {
  lu_byte n_args;
  lua_Number *args;
} TitanVargFloat;
typedef struct {
  lu_byte n_args;
  int *args;
} TitanVargBoolean;
typedef struct {
  lu_byte n_args;
  TString **args;
} TitanVargString;
typedef struct {
  lu_byte n_args;
  Table **args;
} TitanVargArrayOrMap;
typedef struct {
  lu_byte n_args;
  TValue *args;
} TitanVargValue;
typedef struct {
  lu_byte n_args;
  Udata **args;
} TitanVargNominal;
/* The `lu_byte` count is an intentional cap that keeps the struct small and
** bounds static sizing; runtime counts (forwarding/merge, the generic entry)
** are checked against this and raise a clean Titan error when exceeded. */
#define TITAN_VARARG_MAX 200

/* The module state object is a Udata (was a CClosure): push it as a full
   userdata value. Used to seed a function/method/metamethod closure's
   upvalue[0] with the module, and to put the module on the stack. */
#define titan_pushmodule(L, c)                                                 \
  {                                                                            \
    setuvalue(L, s2v(L->top.p), (c));                                          \
    L->top.p++;                                                                \
  }

/*
** Lua 5.5 removed setbvalue (booleans carry no payload; truth lives in
** the tag). This sets a boolean TValue from a C int.
*/
#define titan_setbvalue(obj, x)                                                \
  do {                                                                         \
    if (x) {                                                                   \
      setbtvalue(obj);                                                         \
    } else {                                                                   \
      setbfvalue(obj);                                                         \
    }                                                                          \
  } while (0)

/* Whether a lua_Integer converts to lua_Number with no rounding — replicated
** from lvm.c (l_intfitsf lives only in the .c file). NBM = float mantissa bits.
* */
#define TITAN_NBM (l_floatatt(MANT_DIG))
#if ((((LUA_MAXINTEGER >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) >>              \
      (TITAN_NBM / 4)) >>                                                      \
     (TITAN_NBM - (3 * (TITAN_NBM / 4)))) > 0
#define TITAN_MAXINTFITSF ((lua_Unsigned)1 << TITAN_NBM)
#define titan_intfitsf(i)                                                      \
  ((TITAN_MAXINTFITSF + l_castS2U(i)) <= (2 * TITAN_MAXINTFITSF))
#else
#define titan_intfitsf(i) 1
#endif

/* i < f  (mirrors LTintfloat): i < f  <=>  i < ceil(f) when i doesn't fit a
 * float */
static l_inline int titan_lt_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i))
    return luai_numlt(cast_num(i), f);
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f);
    if (ff != f)
      ff += 1; /* F2Iceil */
    if (lua_numbertointeger(ff, &fi))
      return i < fi;
    else
      return f > 0; /* f beyond integer range */
  }
}
/* i <= f  (LEintfloat): i <= floor(f) */
static l_inline int titan_le_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i))
    return luai_numle(cast_num(i), f);
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f); /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi))
      return i <= fi;
    else
      return f > 0;
  }
}
/* f < i  (LTfloatint): floor(f) < i */
static l_inline int titan_lt_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i))
    return luai_numlt(f, cast_num(i));
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f); /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi))
      return fi < i;
    else
      return f < 0;
  }
}
/* f <= i  (LEfloatint): ceil(f) <= i */
static l_inline int titan_le_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i))
    return luai_numle(f, cast_num(i));
  else {
    lua_Integer fi;
    lua_Number ff = l_floor(f);
    if (ff != f)
      ff += 1; /* F2Iceil */
    if (lua_numbertointeger(ff, &fi))
      return fi <= i;
    else
      return f < 0;
  }
}
/* i == f  (luaV_equalobj int/float case, F2Ieq): equal iff f is integral,
** in range, and equals i. */
static l_inline int titan_eq_intfloat(lua_Integer i, lua_Number f) {
  lua_Integer fi;
  lua_Number ff = l_floor(f);
  if (ff != f)
    return 0; /* non-integral */
  if (!lua_numbertointeger(ff, &fi))
    return 0; /* out of range */
  return i == fi;
}

/*
** Macro to convert between function pointers and object/void pointers.
** These casts are not portable ISO C, but the supported toolchains and
** POSIX dynamic-symbol contract provide them. (The '__extension__' in GNU
** compilers is only to avoid warnings.)
** Named titan_cast_func because Lua 5.5's llimits.h defines its own
** single-argument cast_func.
*/
#if defined(__GNUC__)
#define titan_cast_func(t, p) (__extension__(t)(p))
#else
#define titan_cast_func(t, p) ((t)(p))
#endif

inline static TString *_integer2str(lua_State *L, lua_Integer i) {
  char _cvtbuff[LUA_N2SBUFFSZ];
  size_t len;
  len = (size_t)lua_integer2str(_cvtbuff, sizeof(_cvtbuff), i);
  return luaS_newlstr(L, _cvtbuff, len);
}

inline static TString *_float2str(lua_State *L, lua_Number f) {
  char _cvtbuff[LUA_N2SBUFFSZ];
  TValue _v;
  unsigned len;
  setfltvalue(&_v, f);
  len = luaO_tostringbuff(&_v, _cvtbuff);
  return luaS_newlstr(L, _cvtbuff, len);
}

LUAI_FUNC void *loadlib(lua_State *L, const char *file);
LUAI_FUNC void *loadsym(lua_State *L, void *lib, const char *sym);
LUAI_FUNC void *loadglobalsym(lua_State *L, const char *sym);
LUAI_FUNC void titan_check_abi(lua_State *L, void *lib, const char *sym,
                               const char *file);
LUAI_FUNC void titan_check_types(lua_State *L, void *lib, const char *sym,
                                 const char *file, const char *expected);
LUAI_FUNC void titan_invalidate_backtrace_state(lua_State *L);
LUAI_FUNC void titan_init_paths(lua_State *L);
/* Publish/recover one type-specific canonical pointer. The candidate is an
** opaque identity key and is never dereferenced. The helper preserves the Lua
** stack on success. */
LUAI_FUNC const char *titan_publish_function_type_tag(lua_State *L,
                                                      const char *registry_key,
                                                      const char *candidate);

/*
** Dense Array runtime. A backing Table has no metatable, uses only its array
** part (with slot 0 reserved for the canonical Udata proxy and slots 1..N
** for elements), an empty hash part (nhsize = 0), and stores its logical
** length in lenhint. Mutable proxy uservalue 2 carries the generated
** type-directed Lua writer CClosure; const proxy uservalue 2 is nil.
*/
LUAI_FUNC void titan_array_metatables(lua_State *L, Table **mutable_out,
                                      Table **const_out);
/* Read the already-initialized canonical pair without changing L->top. */
LUAI_FUNC void titan_array_cached_metatables(lua_State *L, Table **mutable_out,
                                             Table **const_out);
LUAI_FUNC Table *titan_array_metatable(lua_State *L);
static l_inline Table *titan_const_array_metatable(lua_State *L) {
  Table *mutable_metatable;
  Table *const_metatable;
  titan_array_metatables(L, &mutable_metatable, &const_metatable);
  cast_void(mutable_metatable);
  return const_metatable;
}

static l_inline lua_Unsigned titan_array_length(const Table *backing) {
  return *lenhint(backing);
}

static l_inline void titan_array_set_length(Table *backing,
                                            lua_Unsigned length) {
  *lenhint(backing) = cast_uint(length);
}

static l_inline Udata *titan_array_require_proxy(Table *backing) {
  lua_assert(backing != NULL && backing->asize > 0);
  lua_assert(*getArrTag(backing, 0) == ctb(LUA_VUSERDATA));
  return gco2u(getArrVal(backing, 0)->gc);
}

static l_inline Udata *titan_array_try_proxy(Table *backing, Table *metatable) {
  if (TITAN_LIKELY(backing->asize > 0)) {
    TValue value;
    arr2obj(backing, 0, &value);
    if (TITAN_LIKELY(ttisfulluserdata(&value))) {
      Udata *maybe_proxy = uvalue(&value);
      if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
        return maybe_proxy;
      }
    }
  }
  return NULL;
}

/* Reject a null/collapsed tag pair before testing either exact identity. */
static l_inline Udata *titan_array_try_proxy_either(Table *backing,
                                                    Table *mutable_metatable,
                                                    Table *const_metatable) {
  Udata *proxy;
  if (mutable_metatable == NULL || const_metatable == NULL ||
      mutable_metatable == const_metatable)
    return NULL;
  proxy = titan_array_try_proxy(backing, mutable_metatable);
  return proxy != NULL ? proxy
                       : titan_array_try_proxy(backing, const_metatable);
}

static l_inline Table *titan_array_try_backing(const TValue *value,
                                               Table *metatable) {
  if (ttisfulluserdata(value)) {
    Udata *maybe_proxy = uvalue(value);
    if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
      return hvalue(&maybe_proxy->uv[0].uv);
    }
  }
  return NULL;
}

static l_inline Table *titan_array_try_backing_either(const TValue *value,
                                                      Table *mutable_metatable,
                                                      Table *const_metatable) {
  if (mutable_metatable == NULL || const_metatable == NULL ||
      mutable_metatable == const_metatable)
    return NULL;
  if (ttisfulluserdata(value)) {
    Udata *maybe_proxy = uvalue(value);
    if (TITAN_LIKELY(maybe_proxy->metatable == mutable_metatable ||
                     maybe_proxy->metatable == const_metatable)) {
      return hvalue(&maybe_proxy->uv[0].uv);
    }
  }
  return NULL;
}

static l_inline Table *titan_array_require_backing(const TValue *value) {
  lua_assert(ttisfulluserdata(value));
  return hvalue(&uvalue(value)->uv[0].uv);
}

LUAI_FUNC Table *titan_array_new_impl(lua_State *L, Table *metatable,
                                      lua_Unsigned capacity,
                                      const TValue *writer, int mutable,
                                      StkId result);

static l_inline Table *titan_array_new(lua_State *L, Table *metatable,
                                       lua_Unsigned capacity,
                                       const TValue *writer, StkId result) {
  return titan_array_new_impl(L, metatable, capacity, writer, 1, result);
}

static l_inline Table *titan_const_array_new(lua_State *L, Table *metatable,
                                             lua_Unsigned capacity,
                                             StkId result) {
  return titan_array_new_impl(L, metatable, capacity, NULL, 0, result);
}

LUAI_FUNC Table *titan_array_shallow_copy(lua_State *L, Table *source,
                                          Table *mutable_metatable,
                                          Table *const_metatable, StkId result);
LUAI_FUNC Table *titan_array_freeze(lua_State *L, Table *backing,
                                    Table *mutable_metatable,
                                    Table *const_metatable);
LUAI_FUNC unsigned titan_array_growth(lua_State *L, lua_Unsigned index);
LUAI_FUNC void titan_array_resize(lua_State *L, Table *backing,
                                  lua_Unsigned capacity);
LUAI_FUNC lu_byte titan_array_get(Table *backing, lua_Integer index,
                                  TValue *result);
LUAI_FUNC void titan_array_set_stack(lua_State *L, Table *backing,
                                     lua_Integer index, int value_index);

static l_inline Table *titan_ensure_metatables_table(lua_State *L) {
  luaL_checkstack(L, 1, "stack overflow creating metatables table");
#ifdef TITAN_COMPILER_TESTS
  lua_pushlightuserdata(L, TITAN_BRAND);
  lua_setfield(L, LUA_REGISTRYINDEX, "TITAN_BRAND");
  lua_pushlightuserdata(L, TITAN_MT_TYPE);
  lua_setfield(L, LUA_REGISTRYINDEX, "TITAN_MT_TYPE");
  lua_pushlightuserdata(L, TITAN_MT_STATICS);
  lua_setfield(L, LUA_REGISTRYINDEX, "TITAN_MT_STATICS");
  lua_pushlightuserdata(L, TITAN_MT_MEMBERMAP);
  lua_setfield(L, LUA_REGISTRYINDEX, "TITAN_MT_MEMBERMAP");
#endif
  lua_getfield(L, LUA_REGISTRYINDEX, TITAN_METATABLES_KEY);
  TValue *v = s2v(L->top.p - 1);
  if (ttisnil(v)) {
    L->top.p--;
    lua_newtable(L);
    v = s2v(L->top.p - 1);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_METATABLES_KEY);
  } else {
    L->top.p--;
  }
  return hvalue(v);
}

#endif
