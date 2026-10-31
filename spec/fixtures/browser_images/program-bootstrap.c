#include <assert.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"
static int fixture_main_bootstrap(lua_State *L) {
    assert(lua_isfunction(L, 1) && lua_type(L, 2) == LUA_TUSERDATA);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_getfield(L, -1, "image_main");
    assert(lua_iscfunction(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, -1, "titan");
    assert(lua_iscfunction(L, -1));
    lua_settop(L, 2);
    lua_getglobal(L, "require");
    lua_pushliteral(L, "titan");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "backtrace");
    assert(lua_iscfunction(L, -1));
    lua_settop(L, 2);
    assert(fputs("support-bootstrap", stdout) >= 0);
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_call(L, 1, 1);
    return 1;
}
void __real_luaL_openselectedlibs(lua_State *L, int load, int preload);
void __wrap_luaL_openselectedlibs(lua_State *L, int load, int preload) {
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    __real_luaL_openselectedlibs(L, load, preload);
    lua_pushcfunction(L, fixture_main_bootstrap);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);
}
