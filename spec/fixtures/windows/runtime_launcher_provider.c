/* The launcher oracle exposes exactly the producer protocol via a .def file.
** Native entries stay private and are reached through the canonical callback. */
#include <assert.h>
#include <string.h>
#include <windows.h>
#include <bcrypt.h>
#include "lua.h"
#include "lauxlib.h"
#include "titan.h"

#ifndef FIXTURE_LAUNCHER_ABI
#define FIXTURE_LAUNCHER_ABI TITAN_ABI_VERSION
#endif

const char *fixture_launcher_abi_value(void) { return FIXTURE_LAUNCHER_ABI; }
int fixture_launcher_abi(lua_State *L) { lua_pushliteral(L, TITAN_ABI_VERSION); return 1; }
int fixture_launcher_types(lua_State *L) { lua_pushliteral(L, "unused oracle metadata"); return 1; }
int fixture_launcher_layouts(lua_State *L) { lua_pushliteral(L, "unused oracle metadata"); return 1; }
int fixture_launcher_compatibility(lua_State *L) { lua_pushliteral(L, "unused oracle metadata"); return 1; }
Udata *fixture_launcher_init(lua_State *L);

/* Deliberately external C linkage but absent from the PE export inventory. */
int fixture_launcher_private_answer(void) {
    unsigned char value;
    assert(BCryptGenRandom(NULL, &value, sizeof(value),
                          BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0);
    return 37;
}

static int fixture_main(lua_State *L) {
    assert(GetACP() == CP_UTF8);
    assert(lua_type(L, 1) == LUA_TUSERDATA);
    lua_len(L, 1);
    assert(lua_tointeger(L, -1) == 2);
    lua_pop(L, 1);
    lua_geti(L, 1, 1);
    assert(strcmp(lua_tostring(L, -1), "one") == 0);
    lua_pop(L, 1);
    lua_geti(L, 1, 2);
    assert(strcmp(lua_tostring(L, -1), "\xc3\xbc") == 0);
    lua_pop(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGC_KEY);
    assert(lua_tointeger(L, -1) == 3);
    lua_pop(L, 1);
    lua_pushinteger(L, fixture_launcher_private_answer());
    return 1;
}

static int fixture_bootstrap(lua_State *L) {
    lua_settop(L, 2); /* main, arguments */
    lua_call(L, 1, 1);
    lua_pushinteger(L, lua_tointeger(L, -1) + 1);
    return 1;
}

static void *fixture_symbols(const char *symbol) {
    if (strcmp(symbol, "fixture_launcher_abi_value") == 0)
        return titan_cast_func(void *, fixture_launcher_abi_value);
    if (strcmp(symbol, "fixture_launcher_init") == 0)
        return titan_cast_func(void *, fixture_launcher_init);
    if (strcmp(symbol, "fixture_launcher_private_answer") == 0)
        return titan_cast_func(void *, fixture_launcher_private_answer);
    return NULL;
}

Udata *fixture_launcher_init(lua_State *L) {
    int top = lua_gettop(L);
    TValue value;
    Udata *module;
    typedef Udata *(*init_fn)(lua_State *);
    TitanModuleProvider dependency = titan_module_provider(L,
        "fixture.beta", "fixture-dependency.dll");
    titan_check_module_abi(L, dependency, "fixture_beta_abi", "fixture-dependency.dll");
    titan_cast_func(init_fn,
        titan_module_symbol(L, dependency, "fixture_beta_init"))(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module fixture.launcher");
    if (lua_isnil(L, -1)) {
        TitanModuleData *data;
        lua_pop(L, 1);
        data = (TitanModuleData *)lua_newuserdatauv(L, sizeof(*data), 0);
        data->symbols = fixture_symbols;
        lua_newtable(L);
        lua_newtable(L);
        lua_pushcfunction(L, fixture_main);
        lua_setfield(L, -2, "main");
        lua_setfield(L, -2, "__index");
        lua_setmetatable(L, -2);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "Titan module fixture.launcher");
        lua_pushcfunction(L, fixture_bootstrap);
        lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);
    }
    value = lua_totvalue(L, -1);
    module = uvalue(&value);
    lua_settop(L, top);
    return module;
}

int luaopen_fixture_launcher(lua_State *L) {
    fixture_launcher_init(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module fixture.launcher");
    return 1;
}
