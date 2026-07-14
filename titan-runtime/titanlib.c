#include "lua.h"
#include "lauxlib.h"

#include <dlfcn.h>

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
#define TITAN_LAZY_LIBS_KEY "b03f87d2-aea4-407c-87df-054d5be15ef2"

#if defined(__GNUC__)
#define titan_cast_func(t, p) (__extension__(t)(p))
#else
#define titan_cast_func(t, p) ((t)(p))
#endif

static void push_lazy_libs(lua_State *L) {
  lua_pushliteral(L, TITAN_LAZY_LIBS_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushliteral(L, TITAN_LAZY_LIBS_KEY);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

/* Internal compiler helper. Titan interfaces are ordinary Lua C functions,
** but package.loadlib maps with RTLD_NOW. Map the image lazily and locally so
** the compiler can inspect its ABI and type symbols without initializing it.
** The registry remembers handles for reuse; no finalizer calls dlclose, so
** mapped Titan interfaces remain available for the process lifetime. */
static int lazyload(lua_State *L) {
  const char *filename = luaL_checkstring(L, 1);
  const char *symbol = luaL_checkstring(L, 2);
  void *lib;
  void *raw;
  const char *error;

  push_lazy_libs(L);
  lua_pushvalue(L, 1);
  lua_rawget(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lib = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);
    if (lib == NULL) {
      error = dlerror();
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_pushstring(L, error != NULL ? error : "dynamic loader error");
      lua_pushliteral(L, "open");
      return 3;
    }
    lua_pushvalue(L, 1);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
  } else {
    lib = lua_touserdata(L, -1);
    lua_pop(L, 1);
  }

  dlerror();
  raw = dlsym(lib, symbol);
  error = dlerror();
  lua_pop(L, 1);
  if (error != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, error);
    lua_pushliteral(L, "init");
    return 3;
  }
  lua_pushcfunction(L, titan_cast_func(lua_CFunction, raw));
  return 1;
}

static int getbacktrace(lua_State *L) {
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  return 1;
}

/* Pin the trace slot: the next error's message handler will KEEP the existing
** TITAN_BACKTRACE_KEY slot instead of regenerating it (one-shot; the handler
** clears the pin). This is the re-raise discipline surfaced for testing;
** catch/re-raise code drives it from generated C. */
static int pintrace(lua_State *L) {
  lua_pushliteral(L, TITAN_TRACE_PINNED);
  lua_pushboolean(L, 1);
  lua_rawset(L, LUA_REGISTRYINDEX);
  return 0;
}

/* Clear the trace slot (and any pin), so the next error regenerates it. */
static int cleartrace(lua_State *L) {
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  lua_pushnil(L);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_pushliteral(L, TITAN_TRACE_PINNED);
  lua_pushnil(L);
  lua_rawset(L, LUA_REGISTRYINDEX);
  return 0;
}

static const luaL_Reg titanlib[] = {
  { "backtrace", getbacktrace },
  { "pin", pintrace },
  { "clear", cleartrace },
  { "_loadlib", lazyload },
  { NULL, NULL }
};

int luaopen_titan(lua_State *L) {
  luaL_newlib(L, titanlib);
  return 1;
}
