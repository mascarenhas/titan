#include "lua.h"
__declspec(dllimport) int titan_lua_loader_dependency(void);
LUAMOD_API int luaopen_titan_loader_canary(lua_State *L) {
    lua_pushinteger(L, titan_lua_loader_dependency());
    return 1;
}
