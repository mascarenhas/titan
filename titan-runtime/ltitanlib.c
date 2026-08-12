#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#include "lua.h"
#include "lauxlib.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
#define TITAN_LAZY_LIBS_KEY "b03f87d2-aea4-407c-87df-054d5be15ef2"
#define TITAN_LAZY_GLOBAL_LIBS_KEY "3f6cae7b-8aeb-42eb-9f72-a978cfe96f7c"

#if defined(__GNUC__)
#define titan_cast_func(t, p) (__extension__(t)(p))
#else
#define titan_cast_func(t, p) ((t)(p))
#endif

static void push_libs(lua_State *L, const char *registry_key) {
  lua_pushstring(L, registry_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushstring(L, registry_key);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

static int push_loader_error(lua_State *L, const char *error,
                             const char *stage) {
  lua_pushnil(L);
  lua_pushstring(L, error != NULL ? error : "dynamic loader error");
  lua_pushstring(L, stage);
  return 3;
}

static int push_path_error(lua_State *L, const char *filename,
                           const char *error) {
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", filename,
                  error != NULL ? error : "dynamic loader error");
  lua_pushliteral(L, "open");
  return 3;
}

static int push_symbol(lua_State *L, void *lib, const char *symbol,
                       const char *requested_filename) {
  void *raw;
  const char *error;

  dlerror();
  raw = dlsym(lib, symbol);
  error = dlerror();
  if (error != NULL) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", requested_filename, error);
    lua_pushliteral(L, "init");
    return 3;
  }
  lua_pushcfunction(L, titan_cast_func(lua_CFunction, raw));
  return 1;
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
  const char *error;

  push_libs(L, TITAN_LAZY_LIBS_KEY);
  lua_pushvalue(L, 1);
  lua_rawget(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lib = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);
    if (lib == NULL) {
      error = dlerror();
      lua_pop(L, 1);
      return push_loader_error(L, error, "open");
    }
    lua_pushvalue(L, 1);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
  } else {
    lib = lua_touserdata(L, -1);
    lua_pop(L, 1);
  }

  lua_pop(L, 1);
  return push_symbol(L, lib, symbol, filename);
}

/* Internal Lua-shim helper. Canonical path keys make aliases share one entry
** in this state's private cache, but the cache remains distinct from both
** Lua's C-library handles and the compiler-only lazy/local cache above. The
** first request in each Lua state therefore always performs a lazy/global
** dlopen, which can promote an image that was mapped locally beforehand.
** Handles are stored as light userdata and are deliberately never closed. */
static int lazyglobalload(lua_State *L) {
  const char *filename = luaL_checkstring(L, 1);
  const char *symbol = luaL_checkstring(L, 2);
  char *canonical;
  void *lib;
  const char *error;
  int error_number;

  errno = 0;
  canonical = realpath(filename, NULL);
  if (canonical == NULL) {
    error_number = errno;
    return push_path_error(L, filename,
                           error_number != 0 ? strerror(error_number)
                                             : "cannot resolve path");
  }

  push_libs(L, TITAN_LAZY_GLOBAL_LIBS_KEY);
  lua_pushstring(L, canonical);
  lua_rawget(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    /* realpath is both the cache identity and the image we actually open.
    ** A bare relative filename (for example one returned by a ?.so package
    ** template) must not be reinterpreted through the platform loader path. */
    lib = dlopen(canonical, RTLD_LAZY | RTLD_GLOBAL);
    if (lib == NULL) {
      error = dlerror();
      lua_pop(L, 1);
      free(canonical);
      return push_path_error(L, filename, error);
    }
    lua_pushstring(L, canonical);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
  } else {
    lib = lua_touserdata(L, -1);
    lua_pop(L, 1);
  }

  lua_pop(L, 1);
  free(canonical);
  return push_symbol(L, lib, symbol, filename);
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
  { "_loadlibglobal", lazyglobalload },
  { NULL, NULL }
};

int luaopen_titan(lua_State *L) {
  luaL_newlib(L, titanlib);
  return 1;
}
