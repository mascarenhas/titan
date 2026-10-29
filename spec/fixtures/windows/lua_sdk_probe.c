/* A real SDK consumer: the library source role exports this module's own
** definitions and never re-exports the Lua API it declares. */
#define LUA_LIB
#include <windows.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lctype.h"
#include "lopcodes.h"
#include "lstate.h"
#include "ltm.h"

LUAMOD_API int luaopen_titan_lua_sdk_probe(lua_State *L) {
    static const char *names[] = {
        "lua_ident", "luai_ctype_", "luaP_opmodes", "luaT_typenames_"
    };
    const void *addresses[] = {
        lua_ident, luai_ctype_, luaP_opmodes, luaT_typenames_
    };
    HMODULE library = GetModuleHandleW(L"lua55.dll");
    unsigned int index;
    luaL_checkversion(L);
    if (library == NULL)
        return luaL_error(L, "controlled Lua DLL is not loaded");
    for (index = 0; index < sizeof(names) / sizeof(names[0]); ++index) {
        if ((const void *)GetProcAddress(library, names[index]) != addresses[index])
            return luaL_error(L, "Lua data import disagrees with %s", names[index]);
    }
    if (sizeof(lua_Integer) != 8 || sizeof(lua_Number) != 8)
        return luaL_error(L, "unexpected configured Lua scalar sizes");
    lua_pushinteger(L, luaO_ceillog2(17));
    return 1;
}
