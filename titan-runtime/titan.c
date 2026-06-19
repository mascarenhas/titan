#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include <execinfo.h>
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"
#include "llimits.h"
#include "titan.h"

static void pushpath (lua_State *L) {
    lua_pushliteral(L, TITAN_PATH_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);

        /* Try the versioned name for the Titan Path variable */
        const char *path = getenv(TITAN_PATH_VAR TITAN_VER_SUFFIX);
        if (path == NULL) {
            /* Try the unversioned name for the Titan Path variable */
            path = getenv(TITAN_PATH_VAR);
        }
        if (path == NULL) {
            /* No Titan Path environment variable */
            path = TITAN_PATH_DEFAULT;
            lua_pushstring(L, path);
        } else {
            path = luaL_gsub(L, path, ";;", ";\1;");
            path = luaL_gsub(L, path, "\1", TITAN_PATH_DEFAULT);
            lua_remove(L, -2); /* remove result from 1st 'gsub' */
        }
        lua_pushliteral(L, TITAN_PATH_KEY);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}

static const char *pushnextdir (lua_State *L, const char *path) {
    const char *l;
    while (*path == ';') path++;  /* skip separators */
    if (*path == '\0') return NULL;  /* no more templates */
    l = strchr(path, ';');  /* find next separator */
    if (l == NULL) l = path + strlen(path);
    lua_pushlstring(L, path, l - path);  /* template */
    return l;
}

static int gctm (lua_State *L) {
    lua_Integer n = luaL_len(L, 1);
    /* for each handle, in reverse order */
    for (; n >= 1; n--) {
        lua_rawgeti(L, 1, n);  /* get handle LIBS[n] */
        dlclose(lua_touserdata(L, -1));
        lua_pop(L, 1);  /* pop handle */
    }
    return 0;
}

static void createlibstable (lua_State *L) {
    lua_newtable(L);
    lua_createtable(L, 0, 1);  /* create metatable */
    lua_pushcfunction(L, gctm);
    lua_setfield(L, -2, "__gc");  /* set finalizer */
    lua_setmetatable(L, -2);
    lua_pushliteral(L, TITAN_LIBS_KEY);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static void pushlibs(lua_State *L) {
    lua_pushliteral(L, TITAN_LIBS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);
        createlibstable(L);
    }
}

void *loadlib (lua_State *L, const char *file) {
    pushlibs(L);
    lua_pushstring(L, file);
    lua_rawget(L, -2); // try to get lib
    if(!lua_isnil(L, -1)) {
        void *lib = lua_touserdata(L, -1);
        lua_pop(L, 2); // pop lib and libs table
        return lib;
    } else {
        lua_pop(L, 1); // pop nil
        pushpath(L);
        const char *path = lua_tostring(L, -1);
        while((path = pushnextdir(L, path)) != NULL) {
            const char *dir = lua_tostring(L, -1);
            lua_pushfstring(L, "%s" TITAN_PATH_SEP "%s", dir, file);
            const char *filename = lua_tostring(L, -1);
            void *lib = dlopen(filename, RTLD_NOW | RTLD_LOCAL);
            if(lib != NULL) {
                lua_pop(L, 3); // pop path, filename, and dir
                lua_pushstring(L, file);
                lua_pushlightuserdata(L, lib);
                lua_rawset(L, -3); // add to libs table
                lua_pop(L, 1); // pop libs table
                return lib;
            }
            lua_pop(L, 2); // pop filename and dir
        }
        lua_pop(L, 2); // pop path and libs table
        luaL_error(L, dlerror());
        return NULL;
    }
}

void *loadsym (lua_State *L, void *lib, const char *sym) {
    void *f = dlsym(lib, sym);
    if(f == NULL) luaL_error(L, dlerror());
    return f;
}

int titan_box_trap (lua_State *L) {
  return luaL_error(L, "internal error: Titan closure variable box called as a function");
}

int errorhandler(lua_State *L) {
  void *buffer[255];
  const int calls = backtrace(buffer, sizeof(buffer) / sizeof(void *));
  char **bt = backtrace_symbols(buffer, calls);
  int top = lua_gettop(L);
  /* Lua 5.5's luaL_Buffer lives on the stack from luaL_buffinit on and
     must stay at the top while in use, so push everything else first */
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  luaL_tolstring(L, top, NULL);
  lua_pushliteral(L, "\n");
  luaL_traceback(L, L, NULL, 0);
  lua_pushliteral(L, "C traceback:\n");
  luaL_Buffer buf;
  luaL_buffinit(L, &buf);
  for(int i = 0; i < calls; i++) {
    if(i > 0) { luaL_addchar(&buf, '\n'); }
    luaL_addstring(&buf, bt[i]);
  }
  luaL_pushresult(&buf);
  lua_concat(L, 5);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_settop(L, top);
  return 1;
}
