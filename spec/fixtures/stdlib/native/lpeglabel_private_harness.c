#include <stdio.h>
#include <stdlib.h>

#include "lauxlib.h"
#include "lualib.h"
#include "titan_lpeglabel.h"

static int traceback(lua_State *L) {
    const char *message = lua_tostring(L, 1);
    if (message == NULL) {
        if (luaL_callmeta(L, 1, "__tostring") &&
            lua_type(L, -1) == LUA_TSTRING) {
            return 1;
        }
        message = "(error object is not a string)";
    }
    luaL_traceback(L, L, message, 1);
    return 1;
}

static int run_suite(lua_State *L, const char *path) {
    int status;
    lua_pushcfunction(L, traceback);
    status = luaL_loadfile(L, path);
    if (status == LUA_OK) {
        status = lua_pcall(L, 0, LUA_MULTRET, -2);
    }
    if (status != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    lua_State *L;
    const char *old_path;

    if (argc != 3) {
        fprintf(stderr, "usage: %s VENDOR_DIR SUITE\n", argv[0]);
        return 2;
    }

    L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "cannot create Lua state\n");
        return 1;
    }
    luaL_openlibs(L);

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, titan_lpeglabel_open);
    lua_setfield(L, -2, "lpeglabel");
    lua_pop(L, 1);

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    old_path = lua_tostring(L, -1);
    lua_pushfstring(L, "%s/?.lua;%s", argv[1],
        old_path == NULL ? "" : old_path);
    lua_setfield(L, -3, "path");
    lua_pop(L, 2);

    if (!run_suite(L, argv[2])) {
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
