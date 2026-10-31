#include <assert.h>
static int preserved_trace(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    const char *trace = lua_tostring(L, -1);
    assert(trace != NULL);
    assert(strstr(trace, "original-browser-error.lua") != NULL);
    assert(strstr(trace, "conversion-browser-error.lua") == NULL);
    assert(fputs("trace-preserved", stdout) >= 0);
    return 0;
}
static int titan_browser_worker(lua_State *L) {
    static const char conversion[] = "return function() error('conversion failed') end";
    static const char original[] = "local object = ...; error(object)";
    static char buffer[BUFSIZ];
    assert(setvbuf(stdout, buffer, _IOFBF, sizeof buffer) == 0);
    luaL_openlibs(L);
    lua_newuserdatauv(L, 1, 0);
    lua_newtable(L);
    lua_pushcfunction(L, preserved_trace);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_setfield(L, LUA_REGISTRYINDEX, "browser-entry-finalizer");
    lua_newtable(L);
    lua_newtable(L);
    assert(luaL_loadbuffer(L, conversion, sizeof conversion - 1, "@conversion-browser-error.lua") == LUA_OK);
    lua_call(L, 0, 1);
    lua_setfield(L, -2, "__tostring");
    lua_setmetatable(L, -2);
    assert(luaL_loadbuffer(L, original, sizeof original - 1, "@original-browser-error.lua") == LUA_OK);
    lua_insert(L, -2);
    lua_call(L, 1, 0);
    lua_pushinteger(L, 0);
    return 1;
}
