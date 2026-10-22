#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0602
#endif

#include "lua.h"
#include "lauxlib.h"

#if defined(_WIN32)
#include "titan.h"
#include "titan_winloader.h"
#else
#include <dlfcn.h>
#endif
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

#if defined(_WIN32)
  raw = titan_cast_func(void *, GetProcAddress((HMODULE)lib, symbol));
  if (raw == NULL) {
    DWORD code = GetLastError();
    lua_pushnil(L);
    titan_win_loader_error(L, "cannot resolve symbol", symbol, code);
    lua_pushfstring(L, "%s: %s", requested_filename, lua_tostring(L, -1));
    lua_remove(L, -2);
    lua_pushliteral(L, "init");
    return 3;
  }
  error = NULL;
#else
  dlerror();
  raw = dlsym(lib, symbol);
  error = dlerror();
#endif
  if (error != NULL) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", requested_filename, error);
    lua_pushliteral(L, "init");
    return 3;
  }
  lua_pushcfunction(L, titan_cast_func(lua_CFunction, raw));
  return 1;
}

#if defined(_WIN32)
static int windows_open_error(lua_State *L) {
  /* titan_win_load_library leaves its diagnostic at the top. */
  lua_pushnil(L);
  lua_insert(L, -2);
  lua_pushliteral(L, "open");
  return 3;
}

static int push_abi_value(lua_State *L, void *lib, const char *symbol) {
  typedef const char *(*titan_abi_value_fn)(void);
  FARPROC raw = GetProcAddress((HMODULE)lib, symbol);
  const char *value;
  if (raw == NULL) {
    DWORD code = GetLastError();
    lua_pushnil(L);
    titan_win_loader_error(L, "cannot resolve ABI query", symbol, code);
    lua_pushliteral(L, "init");
    return 3;
  }
  value = titan_cast_func(titan_abi_value_fn, raw)();
  if (value == NULL)
    return push_loader_error(L, "native ABI query returned NULL", "abi");
  lua_pushstring(L, value);
  return 1;
}

static int canonical_module(lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1));
  return 1;
}

/* Never wrap this plain-C entry as a lua_CFunction. Its result is copied into
** Lua while the provider's retained Windows mapping owns the original bytes. */
static int abivalue(lua_State *L) {
  const char *filename = titan_win_loader_string(L, 1);
  const char *symbol = titan_win_loader_string(L, 2);
  HMODULE lib = titan_win_load_library(L, filename, TITAN_LAZY_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  return push_abi_value(L, lib, symbol);
}
#endif

/* Internal compiler helper. Titan interfaces are ordinary Lua C functions,
** but package.loadlib maps with RTLD_NOW. Map the image lazily and locally so
** the compiler can inspect its ABI and type symbols without initializing it.
** The registry remembers handles for reuse; no finalizer calls dlclose, so
** mapped Titan interfaces remain available for the process lifetime. */
static int lazyload(lua_State *L) {
#if defined(_WIN32)
  const char *filename = titan_win_loader_string(L, 1);
  const char *symbol = titan_win_loader_string(L, 2);
  HMODULE lib = titan_win_load_library(L, filename, TITAN_LAZY_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  return push_symbol(L, lib, symbol, filename);
#else
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
#endif
}

/* Internal Lua-shim helper. Canonical path keys make aliases share one entry
** in this state's private cache, but the cache remains distinct from both
** Lua's C-library handles and the compiler-only lazy/local cache above. The
** first request in each Lua state therefore always performs a lazy/global
** dlopen, which can promote an image that was mapped locally beforehand.
** Handles are stored as light userdata and are deliberately never closed. */
/* Implementation notes: doc/implementation/lua-interop-internals.md#4-generated-shim-lazyglobal-loading-and-promotion */
static int lazyglobalload(lua_State *L) {
#if defined(_WIN32)
  const char *symbol = titan_win_loader_string(L, 2);
  const char *module = titan_win_loader_string(L, 3);
  const char *filename;
  HMODULE lib;
  const char *query, *actual;
  int results;
  luaL_checkstack(L, 6, "looking up a canonical Titan module");
  lua_pushfstring(L, "Titan module %s", module);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_isnil(L, -1)) {
    const TitanModuleData *data;
    if (lua_type(L, -1) != LUA_TUSERDATA ||
        lua_rawlen(L, -1) < sizeof(TitanModuleData))
      return push_loader_error(L, "invalid canonical Titan module state", "init");
    data = (const TitanModuleData *)lua_touserdata(L, -1);
    if (data->symbols == NULL)
      return push_loader_error(L, "invalid canonical Titan module descriptor", "init");
    lua_pushcclosure(L, canonical_module, 1);
    return 1;
  }
  lua_pop(L, 1);
  if (lua_isnoneornil(L, 1))
    return push_loader_error(L, "Titan provider was not found", "open");
  filename = titan_win_loader_string(L, 1);
  lib = titan_win_load_library(L, filename, TITAN_LAZY_GLOBAL_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  if (strncmp(symbol, "luaopen_", 8) != 0)
    return push_loader_error(L, "Titan shim requires a luaopen_ entry", "init");
  query = lua_pushfstring(L, "%s_abi_value", symbol + 8);
  results = push_abi_value(L, lib, query);
  if (results != 1) return results;
  actual = lua_tostring(L, -1);
  if (strcmp(actual, TITAN_ABI_VERSION) != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "Titan compiled module '%s' ABI mismatch: expected "
        TITAN_ABI_VERSION " but found %s", filename, actual);
    lua_pushliteral(L, "abi");
    return 3;
  }
  lua_pop(L, 2); /* ABI query name and copied value */
  return push_symbol(L, lib, symbol, filename);
#else
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
#endif
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
#if defined(_WIN32)
  { "_abivalue", abivalue },
#endif
  { NULL, NULL }
};

LUAMOD_API int luaopen_titan(lua_State *L) {
  luaL_newlib(L, titanlib);
  return 1;
}
