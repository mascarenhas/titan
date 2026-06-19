#ifndef TITAN_H
#define TITAN_H

#include <float.h>
#include <math.h>
#include <stdio.h>

#include "luaconf.h"
#include "lobject.h"
#include "lstring.h"
#include "llimits.h"
#include "lvm.h"

#ifdef __GNUC__
#define TITAN_LIKELY(x)   __builtin_expect((x), 1)
#define TITAN_UNLIKELY(x) __builtin_expect((x), 0)
#else
#define TITAN_LIKELY(x)   (x)
#define TITAN_UNLIKELY(x) (x)
#endif

/* 0.5 -> 0.6: the native ABI changed (every entry gained the _fn closure
   parameter for lexical closures), so 0.5-compiled .so modules are
   ABI-incompatible and must not be mixed with 0.6 ones.
   0.6 -> 0.7: record instances and module state (_mod) are now a single Lua 5.5
   Udata (was a CClosure + Udata wrapper). The native ABI of every function
   taking/returning a record changed (ctype CClosure* -> Udata*), and
   <mangled>_init now returns Udata* (was CClosure*). 0.6-compiled .so modules
   are ABI-incompatible with 0.7 ones and live under a different TITAN_PATH dir. */
#define TITAN_VER          "0.7"
#define TITAN_VER_SUFFIX   "_0_7"
#define TITAN_PATH_VAR     "TITAN_PATH"
#define TITAN_PATH_SEP     "/"
#define TITAN_PATH_DEFAULT ".;/usr/local/lib/titan/" TITAN_VER
#define TITAN_PATH_KEY     "ec10e486-d8fd-11e7-87f4-e7e9581a929c"
#define TITAN_LIBS_KEY     "ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"

#define TITAN_LUAINTEGER_NBITS cast_int(sizeof(lua_Integer) * CHAR_BIT)

/* The module state object is a Udata (was a CClosure): push it as a full
   userdata value. Used to seed a function/method/metamethod closure's
   upvalue[0] with the module, and to put the module on the stack. */
#define titan_pushmodule(L, c) { setuvalue(L, s2v(L->top.p), (c)); L->top.p++; }

/*
** Lua 5.5 removed setbvalue (booleans carry no payload; truth lives in
** the tag). This sets a boolean TValue from a C int.
*/
#define titan_setbvalue(obj,x) \
    do { if (x) { setbtvalue(obj); } else { setbfvalue(obj); } } while (0)

/* Whether a lua_Integer converts to lua_Number with no rounding — replicated
** from lvm.c (l_intfitsf lives only in the .c file). NBM = float mantissa bits. */
#define TITAN_NBM (l_floatatt(MANT_DIG))
#if ((((LUA_MAXINTEGER >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) \
        >> (TITAN_NBM - (3 * (TITAN_NBM / 4)))) > 0
#define TITAN_MAXINTFITSF ((lua_Unsigned)1 << TITAN_NBM)
#define titan_intfitsf(i) ((TITAN_MAXINTFITSF + l_castS2U(i)) <= (2 * TITAN_MAXINTFITSF))
#else
#define titan_intfitsf(i) 1
#endif

/* i < f  (mirrors LTintfloat): i < f  <=>  i < ceil(f) when i doesn't fit a float */
static l_inline int titan_lt_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i)) return luai_numlt(cast_num(i), f);
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);
    if (ff != f) ff += 1;                       /* F2Iceil */
    if (lua_numbertointeger(ff, &fi)) return i < fi;
    else return f > 0;                          /* f beyond integer range */
  }
}
/* i <= f  (LEintfloat): i <= floor(f) */
static l_inline int titan_le_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i)) return luai_numle(cast_num(i), f);
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);  /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi)) return i <= fi;
    else return f > 0;
  }
}
/* f < i  (LTfloatint): floor(f) < i */
static l_inline int titan_lt_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i)) return luai_numlt(f, cast_num(i));
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);  /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi)) return fi < i;
    else return f < 0;
  }
}
/* f <= i  (LEfloatint): ceil(f) <= i */
static l_inline int titan_le_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i)) return luai_numle(f, cast_num(i));
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);
    if (ff != f) ff += 1;                        /* F2Iceil */
    if (lua_numbertointeger(ff, &fi)) return fi <= i;
    else return f < 0;
  }
}
/* i == f  (luaV_equalobj int/float case, F2Ieq): equal iff f is integral,
** in range, and equals i. */
static l_inline int titan_eq_intfloat(lua_Integer i, lua_Number f) {
  lua_Integer fi; lua_Number ff = l_floor(f);
  if (ff != f) return 0;                         /* non-integral */
  if (!lua_numbertointeger(ff, &fi)) return 0;   /* out of range */
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
#define titan_cast_func(t,p) (__extension__ (t)(p))
#else
#define titan_cast_func(t,p) ((t)(p))
#endif

inline static TString* _integer2str (lua_State *L, lua_Integer i) {
    char _cvtbuff[LUA_N2SBUFFSZ];
    size_t len;
    len = (size_t)lua_integer2str(_cvtbuff, sizeof(_cvtbuff), i);
    return luaS_newlstr(L, _cvtbuff, len);
}

inline static TString* _float2str (lua_State *L, lua_Number f) {
    char _cvtbuff[LUA_N2SBUFFSZ];
    TValue _v;
    unsigned len;
    setfltvalue(&_v, f);
    len = luaO_tostringbuff(&_v, _cvtbuff);
    return luaS_newlstr(L, _cvtbuff, len);
}

LUAI_FUNC void *loadlib (lua_State *L, const char *file);
LUAI_FUNC void *loadsym (lua_State *L, void *lib, const char *sym);

int errorhandler(lua_State *L);

#endif
