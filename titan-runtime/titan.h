#ifndef TITAN_H
#define TITAN_H

#include <float.h>
#include <math.h>
#include <stdio.h>

#include "llimits.h"
#include "lobject.h"
#include "lstring.h"
#include "luaconf.h"
#include "lvm.h"

/* The vendored `lua_longjmp` struct + statement-form `TITAN_SETJMP`, used by
 * the
 ** generated module C to install the inline catch/finally setjmp boundary. */
#include "titan_longjmp.h"

#ifdef __GNUC__
#define TITAN_LIKELY(x) __builtin_expect((x), 1)
#define TITAN_UNLIKELY(x) __builtin_expect((x), 0)
#define TITAN_UNUSED __attribute__((unused))
#else
#define TITAN_LIKELY(x) (x)
#define TITAN_UNLIKELY(x) (x)
#define TITAN_UNUSED
#endif

/* 0.5 -> 0.6: the native ABI changed (every entry gained the _fn closure
   parameter for lexical closures), so 0.5-compiled .so modules are
   ABI-incompatible and must not be mixed with 0.6 ones.
   0.6 -> 0.7: record instances and module state (_mod) are now a single Lua 5.5
   Udata (was a CClosure + Udata wrapper). The native ABI of every function
   taking/returning a record changed (ctype CClosure* -> Udata*), and
   <mangled>_init now returns Udata* (was CClosure*). 0.6-compiled .so modules
   are ABI-incompatible with 0.7 ones and live under a different TITAN_PATH dir.
   0.7 -> 0.8: a record's type identity moved from a getudatamem tag word to the
   udata's metatable pointer. Record instances now carry no raw payload
   (luaS_newudata(L, 0, N)), and a type check compares uvalue(v)->metatable
   against the expected record metatable. A 0.7 checker reading a 0.8 record's
   getudatamem would read out-of-bounds, so 0.7 and 0.8 .so modules are
   ABI-incompatible and live under a different TITAN_PATH dir.
   0.8 -> 0.9: variadic parameters. A variadic function's native signature
   gained a trailing `TitanVargX *_varargs, int _start` pair (after the declared
   params, before the out-params), and <mangled>_types now encodes the
   `varargtype` element type for variadic functions and methods. A 0.8 module
   has neither, so 0.8 and 0.9 .so modules are ABI-incompatible and live under a
   different TITAN_PATH dir. 0.9 -> 0.10: TitanVargX changed from an inline
   flexible-array backing object
   (`lu_byte n_args; T args[]`) to a descriptor (`lu_byte n_args; T *args`).
   The native parameter type name is unchanged, but its layout and the meaning
   of the bytes following n_args are not: mixing the two forms across a .so
   boundary misreads argument storage. 0.9 and 0.10 modules are therefore
   ABI-incompatible and must live under different TITAN_PATH directories.
   0.10 -> 0.11: records can have module-local declarations and members. The
   serialized <mangled>_types interface omits local records and local record
   members while preserving record field-slot counts, so 0.10 and 0.11 .so
   modules disagree about what a compiled record interface means. */
#define TITAN_VER "0.11"
#define TITAN_VER_SUFFIX "_0_11"
#define TITAN_PATH_VAR "TITAN_PATH"
#define TITAN_PATH_SEP "/"
#define TITAN_PATH_DEFAULT ".;/usr/local/lib/titan/" TITAN_VER
#define TITAN_PATH_KEY "ec10e486-d8fd-11e7-87f4-e7e9581a929c"
#define TITAN_LIBS_KEY "ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"
#define TITAN_BT_GENERATION_KEY "a222927d-0e7b-4f7a-93d9-1a6ce7111a5c"

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"

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

/* When set (boolean true) in the registry, errorhandler() KEEPS the existing
** TITAN_BACKTRACE_KEY slot instead of regenerating it, and clears the pin. A
** pending re-raise sets the pin so the original error's trace is preserved; a
** fresh error leaves it clear so it gets a freshly-captured trace. */
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"

/* Temporary handoff slot used by Titan coroutines. A dead coroutine entry
** stages its own trace here; the resume/error side captures a new propagation
** trace, appends it, stores the combined trace in TITAN_BACKTRACE_KEY, and
** sets TITAN_TRACE_PINNED for the final re-raise. */
#define TITAN_TRACE_APPEND_KEY "4f895b66-bae0-4e97-afb3-83a31f2f9e96"

#define TITAN_LUAINTEGER_NBITS cast_int(sizeof(lua_Integer) * CHAR_BIT)

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
** Macro to convert pointer-to-void* to pointer-to-function. This cast
** is undefined according to ISO C, but POSIX assumes that it works.
** (The '__extension__' in gnu compilers is only to avoid warnings.)
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
LUAI_FUNC void titan_check_abi(lua_State *L, void *lib, const char *sym,
                               const char *file);
LUAI_FUNC void titan_invalidate_backtrace_state(lua_State *L);

TValue lua_totvalue(lua_State *L, int idx);
void lua_pushtvalue(lua_State *L, TValue v);
void *lua_togco(lua_State *L, int idx);

int errorhandler(lua_State *L);

#endif
