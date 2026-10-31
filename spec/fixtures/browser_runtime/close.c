#include "../../stdlib/titan/coroutine/tests/browser_close.h"
#include <lauxlib.h>
#include <lualib.h>
#include <titan/ffi.h>
#include <stdio.h>
#include <string.h>

static int counts[3];
void browser_close_record(int event) {
  if (event >= 0 && event < 3) ++counts[event];
}

/* This is the same descriptor-preserving snapshot used by titan.lua. It
 * copies no initialized module userdata between collectors. All child setup
 * and user code run inside its real lua_pcall; parent stack is restored on
 * either outcome before child close. */
static int close_worker(lua_State *child) {
  lua_State *parent = lua_touserdata(child, 1);
  luaL_openlibs(child);
  titan_install_searcher(child);
  lua_getfield(parent, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushnil(parent);
  while (lua_next(parent, -2)) {
    if (lua_type(parent, -2) == LUA_TSTRING && lua_iscfunction(parent, -1)) {
      size_t length;
      const char *name = lua_tolstring(parent, -2, &length);
      lua_CFunction loader = lua_tocfunction(parent, -1);
      TitanModuleSymbols symbols = titan_module_preload_symbols(parent, name, length, loader);
      titan_module_preload(child, name, length, loader, symbols);
    }
    lua_pop(parent, 1);
  }
  lua_pop(parent, 1);
  lua_getglobal(child, "require");
  lua_pushliteral(child, "coroutine.tests");
  lua_call(child, 1, 1);
  lua_getfield(child, -1, "browser_retained_close");
  lua_call(child, 0, 0);
  return 0;
}

int browser_close_probe(lua_State *parent) {
  lua_State *child;
  int top = lua_gettop(parent), status;
  char message[512] = "cannot create child Lua state";
  if (!lua_checkstack(parent, 4))
    return luaL_error(parent, "cannot reserve parent preload snapshot stack");
  child = luaL_newstate();
  memset(counts, 0, sizeof counts);
  if (!child) return luaL_error(parent, "%s", message);
  lua_pushcfunction(child, close_worker);
  lua_pushlightuserdata(child, parent);
  status = lua_pcall(child, 1, 0, 0);
  if (status != LUA_OK) {
    const char *failure = lua_tostring(child, -1);
    snprintf(message, sizeof message, "%s", failure ? failure : "child close setup failed");
  }
  lua_settop(parent, top);
  lua_close(child);
  if (status != LUA_OK) return luaL_error(parent, "%s", message);
  if (counts[0] != 1 || counts[1] != 1 || counts[2] != 0) return -1;
  return 3;
}
