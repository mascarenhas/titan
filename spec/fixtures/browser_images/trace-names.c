#include <string.h>
#include "lua.h"
#include "titan.h"
#include "trace-names.h"

int trace_names_resolves(lua_State *L, const char *symbol, const char *expected) {
    int top = lua_gettop(L);
    int status = 17;
    lua_pushliteral(L, TITAN_NAMES_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_istable(L, -1)) {
        lua_pushstring(L, symbol);
        lua_rawget(L, -2);
        if (lua_type(L, -1) == LUA_TSTRING && strcmp(lua_tostring(L, -1), expected) == 0)
            status = 0;
    }
    lua_settop(L, top);
    return status;
}
