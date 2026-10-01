/* Native Windows loader oracle. Compile this into independent providers; only
** the controlled Lua import library is used, never a Titan import library. */
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "titan.h"

#define EXPORT __declspec(dllexport)
#ifndef FIXTURE_ABI
#define FIXTURE_ABI TITAN_ABI_VERSION
#endif

static void increment(lua_State *L, const char *key) {
    lua_Integer count;
    lua_getfield(L, LUA_REGISTRYINDEX, key);
    count = lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_pushinteger(L, count + 1);
    lua_setfield(L, LUA_REGISTRYINDEX, key);
}

static Udata *module_state(lua_State *L, const char *key,
                            TitanModuleSymbols symbols) {
    int top = lua_gettop(L);
    TValue value;
    Udata *module;
    lua_getfield(L, LUA_REGISTRYINDEX, key);
    if (lua_isnil(L, -1)) {
        TitanModuleData *data;
        lua_pop(L, 1);
        data = (TitanModuleData *)lua_newuserdatauv(L, sizeof(*data), 0);
        data->symbols = symbols;
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, key);
        increment(L, "fixture.init.calls");
    }
    value = lua_totvalue(L, -1);
    module = uvalue(&value);
    lua_settop(L, top);
    return module;
}

#if defined(FIXTURE_DEPENDENCY)
EXPORT const char *fixture_beta_abi_value(void) { return TITAN_ABI_VERSION; }
EXPORT Udata *fixture_beta_init(lua_State *L);
static void *beta_symbols(const char *symbol) {
    if (strcmp(symbol, "fixture_beta_abi_value") == 0)
        return titan_cast_func(void *, fixture_beta_abi_value);
    if (strcmp(symbol, "fixture_beta_init") == 0)
        return titan_cast_func(void *, fixture_beta_init);
    return NULL;
}
EXPORT Udata *fixture_beta_init(lua_State *L) {
    return module_state(L, "Titan module fixture.beta", beta_symbols);
}
#else
#if !defined(FIXTURE_OMIT_VALUE)
EXPORT const char *fixture_alpha_abi_value(void) { return FIXTURE_ABI; }
#endif
EXPORT const char *fixture_gamma_abi_value(void) { return TITAN_ABI_VERSION; }
EXPORT Udata *fixture_alpha_init(lua_State *L);
EXPORT Udata *fixture_gamma_init(lua_State *L);

EXPORT int fixture_alpha_abi(lua_State *L) {
    increment(L, "fixture.legacy.calls");
    lua_pushliteral(L, TITAN_ABI_VERSION);
    return 1;
}

static int fixture_finalize(lua_State *L) {
    increment(L, "fixture.finalizer.calls");
    return 0;
}

LUAMOD_API int fixture_make_finalizer(lua_State *L) {
    lua_newuserdatauv(L, 1, 0);
    lua_newtable(L);
    lua_pushcfunction(L, fixture_finalize);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    return 1;
}

static void *alpha_symbols(const char *symbol) {
#if !defined(FIXTURE_OMIT_VALUE)
    if (strcmp(symbol, "fixture_alpha_abi_value") == 0)
        return titan_cast_func(void *, fixture_alpha_abi_value);
#endif
    if (strcmp(symbol, "fixture_alpha_init") == 0)
        return titan_cast_func(void *, fixture_alpha_init);
    return NULL;
}

static void *gamma_symbols(const char *symbol) {
    if (strcmp(symbol, "fixture_gamma_abi_value") == 0)
        return titan_cast_func(void *, fixture_gamma_abi_value);
    if (strcmp(symbol, "fixture_gamma_init") == 0)
        return titan_cast_func(void *, fixture_gamma_init);
    return NULL;
}

EXPORT Udata *fixture_alpha_init(lua_State *L) {
    typedef Udata *(*init_fn)(lua_State *);
    TitanModuleProvider dependency = titan_module_provider(L,
        "fixture.beta", "fixture-dependency.dll");
    titan_check_module_abi(L, dependency, "fixture_beta_abi", "fixture-dependency.dll");
    titan_cast_func(init_fn, titan_module_symbol(L, dependency, "fixture_beta_init"))(L);
    return module_state(L, "Titan module fixture.alpha", alpha_symbols);
}

EXPORT Udata *fixture_gamma_init(lua_State *L) {
    return module_state(L, "Titan module fixture.gamma", gamma_symbols);
}

LUAMOD_API int luaopen_fixture_alpha(lua_State *L) {
    fixture_alpha_init(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module fixture.alpha");
    return 1;
}

LUAMOD_API int luaopen_fixture_gamma(lua_State *L) {
    fixture_gamma_init(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module fixture.gamma");
    return 1;
}
#endif
