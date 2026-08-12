#ifndef TITAN_FFI_H
#define TITAN_FFI_H

#include "lauxlib.h"
#include "ldo.h"
#include "lstate.h"

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
#define TITAN_TRACE_APPEND_KEY "4f895b66-bae0-4e97-afb3-83a31f2f9e96"
#define TITAN_MAIN_BOOTSTRAP_KEY "41c48a97-55a5-4514-a76f-79ab028ae6e0"
#define TITAN_MAIN_ARGC_KEY "fd9c8d85-f521-4052-92e6-8af5c349e5bb"
#define TITAN_MAIN_ARGV_KEY "fc1376f3-2cb7-48d4-969c-c02df930cf68"

typedef void titan_ffi_void;
typedef void *titan_ffi_void_ptr;
typedef char *titan_ffi_char_ptr;
typedef _Bool titan_ffi_bool;
typedef char titan_ffi_char;
typedef signed char titan_ffi_signed_char;
typedef unsigned char titan_ffi_unsigned_char;
typedef short titan_ffi_short;
typedef unsigned short titan_ffi_unsigned_short;
typedef int titan_ffi_int;
typedef unsigned int titan_ffi_unsigned_int;
typedef long titan_ffi_long;
typedef unsigned long titan_ffi_unsigned_long;
typedef long long titan_ffi_long_long;
typedef unsigned long long titan_ffi_unsigned_long_long;
typedef float titan_ffi_float;
typedef double titan_ffi_double;
typedef long double titan_ffi_long_double;

int errorhandler(lua_State *L);

static inline TValue lua_totvalue(lua_State *L, int idx) {
    TValue value;
    lua_pushvalue(L, idx);
    value = *s2v(L->top.p - 1);
    L->top.p--;
    return value;
}

static inline void lua_pushtvalue(lua_State *L, TValue value) {
    setobj2s(L, L->top.p, &value);
    L->top.p++;
}

static inline void *lua_togco(lua_State *L, int idx) {
    TValue value = lua_totvalue(L, idx);
    return gcvalue(&value);
}

static inline lua_State *titan_newthread(lua_State *L) {
    lua_State *thread = lua_newthread(L);
    /* Native coroutine entry bypasses a Lua entry wrapper. Reserve enough
     * stack while the parent call still owns the ordinary protected boundary,
     * so the generated function-scope catch can install its jump target before
     * its first potentially allocating GC check. */
    if (!lua_checkstack(thread, LUA_MINSTACK))
        luaL_error(L, "cannot reserve stack for Titan coroutine entry");
    lua_pushcfunction(thread, errorhandler);
    thread->errfunc = savestack(thread, thread->top.p - 1);
    return thread;
}

static inline lua_State *lmacro_thvalue(const TValue *o) {
    return thvalue(o);
}

static inline Udata *lmacro_uvalue(const TValue *o) {
    return uvalue(o);
}

static inline CClosure *lmacro_clCvalue(const TValue *o) {
    return clCvalue(o);
}

static inline void *lmacro_pvalue(const TValue *o) {
    return pvalue(o);
}

#endif
