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

#define TITAN_VER          "0.5"
#define TITAN_VER_SUFFIX   "_0_5"
#define TITAN_PATH_VAR     "TITAN_PATH"
#define TITAN_PATH_SEP     "/"
#define TITAN_PATH_DEFAULT ".;/usr/local/lib/titan/" TITAN_VER
#define TITAN_PATH_KEY     "ec10e486-d8fd-11e7-87f4-e7e9581a929c"
#define TITAN_LIBS_KEY     "ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"

#define TITAN_LUAINTEGER_NBITS cast_int(sizeof(lua_Integer) * CHAR_BIT)

#define titan_pushmodule(L, c) { setclCvalue(L, s2v(L->top.p), (c)); L->top.p++; }

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
