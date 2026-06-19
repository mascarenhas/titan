#ifndef TITAN_H
#define TITAN_H

#include "luaconf.h"
#include "lobject.h"
#include "lstring.h"

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
   are ABI-incompatible with 0.7 ones and live under a different TITAN_PATH dir.
   0.7 -> 0.8: a record's type identity moved from a getudatamem tag word to the
   udata's metatable pointer. Record instances now carry no raw payload
   (luaS_newudata(L, 0, N)), and a type check compares uvalue(v)->metatable
   against the expected record metatable. A 0.7 checker reading a 0.8 record's
   getudatamem would read out-of-bounds, so 0.7 and 0.8 .so modules are
   ABI-incompatible and live under a different TITAN_PATH dir. */
#define TITAN_VER          "0.8"
#define TITAN_VER_SUFFIX   "_0_8"
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
