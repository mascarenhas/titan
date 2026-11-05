#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <lauxlib.h>
#include <lualib.h>
#include <titan.h>
#include "gate.h"
#include "fixture_controls.h"

extern int luaopen_titan(lua_State *L);
extern int luaopen_titan_coroutine(lua_State *L);
extern int luaopen_entry_lifetimes(lua_State *L);
static lua_State *owned_state;
static int phase;

static int entry_operation(lua_State *L) {
  static const char *const operations[] = {"prepare", "resume", "finish"};
  if (phase == 0) {
    titan_browser_attach(L);
    luaL_openlibs(L);
    luaL_requiref(L, "titan", luaopen_titan, 0); lua_pop(L, 1);
    titan_install_searcher(L);
    luaL_requiref(L, "titan.coroutine", luaopen_titan_coroutine, 0); lua_pop(L, 1);
    luaL_requiref(L, "entry_lifetimes", luaopen_entry_lifetimes, 0); lua_pop(L, 1);
  }
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, "entry_lifetimes");
  lua_getfield(L, -1, operations[phase]);
  lua_call(L, 0, 0);
  return 0;
}

static int close_owned(lua_State *L) {
  (void)L;
  if (owned_state) {
    lua_State *child = owned_state;
    owned_state = NULL;
    titan_browser_close_state(child);
  }
  return 0;
}
int gate_lifetime_is_child(lua_State *L) { return L == owned_state; }

/* These workers are reached through original Titan Callable values and the
 * production protected invoke gateway. The separate state is owned between
 * entry lifetimes, with its own earliest/last bridge registry. */
void gate_lifetime_operation(lua_State *parent, int requested_phase) {
  int top, status;
  assert(phase >= 0 && phase < 3 && requested_phase == phase);
  if (phase == 0) {
    top = lua_gettop(parent);
    luaL_checkstack(parent, 3, "independent entry owner");
    lua_newuserdatauv(parent, 1, 0);
    lua_newtable(parent);
    lua_pushcfunction(parent, close_owned); lua_setfield(parent, -2, "__gc");
    lua_setmetatable(parent, -2);
    lua_setfield(parent, LUA_REGISTRYINDEX, "entry lifetime state owner");
    lua_settop(parent, top);
    owned_state = luaL_newstate();
    assert(owned_state != NULL);
  }
  top = lua_gettop(owned_state);
  assert(lua_checkstack(owned_state, 5));
  lua_pushcfunction(owned_state, errorhandler);
  lua_pushcfunction(owned_state, entry_operation);
  status = lua_pcall(owned_state, 0, 0, top + 1);
  if (status != LUA_OK) {
    fprintf(stderr, "entry lifetime phase %d: %s\n", phase, lua_tostring(owned_state, -1));
    fflush(stderr);
    abort();
  }
  lua_settop(owned_state, top);
  ++phase;
  if (phase == 3) close_owned(parent);
}

int titan_browser_gate_guarded(uint64_t operation_id) {
  jmp_buf target;
  titan_browser_completion completion = {0};
  if (!operation_id || !titan_browser_entry_allowed(operation_id, TITAN_BROWSER_INVOKE)) return -1;
  if (!setjmp(target)) longjmp(target, 1);
  completion.operation_id = operation_id;
  completion.operation = TITAN_BROWSER_INVOKE;
  completion.application_status = 1;
  titan_browser_complete(&completion);
  return 0;
}
unsigned int titan_browser_gate_observe(void) { return (unsigned int)phase; }
