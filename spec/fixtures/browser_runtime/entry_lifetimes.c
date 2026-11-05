#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <titan/ffi.h>

extern int titan_browser_entry_allowed(void);
extern int luaopen_titan(lua_State *L);
extern int luaopen_titan_coroutine(lua_State *L);
extern int luaopen_entry_lifetimes(lua_State *L);
static lua_State *owned_state;
static int phase;

/* Each call has a fresh protected root C invocation. The child state and its
 * actual compiled Titan module own the coroutines between those invocations. */
static int entry_operation(lua_State *L) {
  static const char *const operations[] = {"prepare", "resume", "finish"};
  if (phase == 0) {
    luaL_openlibs(L);
    luaL_requiref(L, "titan", luaopen_titan, 0);
    lua_pop(L, 1);
    titan_install_searcher(L);
    luaL_requiref(L, "titan.coroutine", luaopen_titan_coroutine, 0);
    lua_pop(L, 1);
    luaL_requiref(L, "entry_lifetimes", luaopen_entry_lifetimes, 0);
    lua_pop(L, 1);
  }
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, "entry_lifetimes");
  lua_getfield(L, -1, operations[phase]);
  lua_call(L, 0, 0);
  return 0;
}

int titan_browser_gate_guarded(void) {
  int status;
  assert(titan_browser_entry_allowed());
  assert(phase >= 0 && phase < 3);
  if (phase == 0) {
    owned_state = luaL_newstate();
    assert(owned_state != NULL);
  }
  lua_pushcfunction(owned_state, entry_operation);
  status = lua_pcall(owned_state, 0, 0, 0);
  if (status != LUA_OK) {
    fprintf(stderr, "entry lifetime phase %d: %s\n", phase,
      lua_tostring(owned_state, -1));
    fflush(stderr);
    abort();
  }
  ++phase;
  if (phase == 3) {
    lua_close(owned_state);
    owned_state = NULL;
  }
  return phase;
}

/* State-neutral observation must not create another logical entry. */
unsigned int titan_browser_gate_observe(void) { return (unsigned int)phase; }
