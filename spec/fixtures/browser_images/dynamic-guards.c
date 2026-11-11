#include <assert.h>
extern int luaopen_titan(lua_State *L);
static int dynamic_attempt(lua_State *L) {
    int which = (int)lua_tointeger(L, lua_upvalueindex(1));
    switch (which) {
        case 0: (void)loadlib(L, "missing-provider.so"); break;
        case 1: (void)loadsym(L, (void *)(uintptr_t)1, "missing_symbol"); break;
        case 2: {
            TitanModuleProvider provider = { (void *)(uintptr_t)1, NULL };
            (void)titan_module_symbol(L, provider, "missing_symbol");
            break;
        }
        default:
            lua_getfield(L, LUA_REGISTRYINDEX, "browser-guard-support");
            lua_getfield(L, -1, which == 3 ? "_loadlib" : "_loadlibglobal");
            lua_pushliteral(L, "missing-provider.so");
            lua_pushliteral(L, "missing_symbol");
            lua_pushliteral(L, "missing_module");
            lua_call(L, 3, 0);
    }
    return 0;
}
static int titan_browser_worker(lua_State *L) {
    static const char *const expected[] = {
        "browser target does not support dynamic provider loading",
        "browser target symbol lookup requires an explicit provider symbol table",
        "Titan module provider is missing symbol 'missing_symbol': browser target symbol lookup requires an explicit provider symbol table",
        "browser target does not support dynamic provider loading",
        "browser target does not support dynamic provider loading",
    };
    luaL_openlibs(L);
    luaL_requiref(L, "titan", luaopen_titan, 0);
    lua_setfield(L, LUA_REGISTRYINDEX, "browser-guard-support");
    for (int i = 0; i < 5; i++) {
        lua_pushinteger(L, i);
        lua_pushcclosure(L, dynamic_attempt, 1);
        assert(lua_pcall(L, 0, 0, 0) == LUA_ERRRUN);
        assert(strcmp(lua_tostring(L, -1), expected[i]) == 0);
        lua_pop(L, 1);
    }
    assert(fputs("dynamic-guards=5", stdout) >= 0);
    lua_pushinteger(L, 0);
    return 1;
}
