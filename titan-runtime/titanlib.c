#include "lua.h"
#include "lauxlib.h"

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"

static int getbacktrace(lua_State *L) {
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  return 1;
}

/* Pin the trace slot: the next error's message handler will KEEP the existing
** TITAN_BACKTRACE_KEY slot instead of regenerating it (one-shot; the handler
** clears the pin). This is the re-raise discipline (plan A.5) surfaced for
** testing; later phases (catch/re-raise) drive it from generated C. */
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
  { NULL, NULL }
};

int luaopen_titan(lua_State *L) {
  luaL_newlib(L, titanlib);
  return 1;
}
