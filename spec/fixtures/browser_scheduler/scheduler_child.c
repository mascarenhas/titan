#include <lauxlib.h>
#include <lualib.h>
#include <titan.h>
#include "../../stdlib/titan/async/browser_tests/child.h"

extern int luaopen_titan(lua_State *L);
extern int luaopen_async_browser_child(lua_State *L);

/* An independent Lua state created by C code: never the instance owner. No
 * Titan API creates one on the browser yet (lua.new is #335). */
typedef struct child_owner { lua_State *child; } child_owner;

static int child_gc(lua_State *L) {
  child_owner *owner = (child_owner *)lua_touserdata(L, 1);
  if (owner->child) {
    lua_State *child = owner->child;
    owner->child = NULL;
    lua_close(child);
  }
  return 0;
}

static int child_bootstrap(lua_State *L) {
  luaL_openlibs(L);
  titan_install_searcher(L);
  luaL_requiref(L, "titan", luaopen_titan, 0); lua_pop(L, 1);
  luaL_requiref(L, "async.browser_child", luaopen_async_browser_child, 0);
  lua_getfield(L, -1, "publication");
  lua_call(L, 0, 0);
  return 0;
}

static int child_check(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, "async.browser_child");
  lua_getfield(L, -1, "check");
  lua_call(L, 0, 0);
  return 0;
}

/* Run worker in the child, synchronously, as child:run will; a failure is
 * raised in the parent with the child's message. */
static void child_call(lua_State *parent, lua_State *child, lua_CFunction worker) {
  int top = lua_gettop(child);
  if (!lua_checkstack(child, 2)) luaL_error(parent, "scheduler child stack allocation failed");
  lua_pushcfunction(child, errorhandler);
  lua_pushcfunction(child, worker);
  if (lua_pcall(child, 0, 0, top + 1) != LUA_OK) {
    const char *message = lua_tostring(child, -1);
    lua_pushfstring(parent, "scheduler child: %s", message ? message : "non-string failure");
    lua_settop(child, top);
    lua_error(parent);
  }
  lua_settop(child, top);
}

static child_owner *get_owner(lua_State *L, TValue value) {
  if (!ttisfulluserdata(&value)) luaL_error(L, "scheduler child owner is not userdata");
  return (child_owner *)getudatamem(uvalue(&value));
}

TValue scheduler_new_child(lua_State *L) {
  child_owner *owner;
  TValue value;
  int top = lua_gettop(L);
  luaL_checkstack(L, 3, "scheduler child owner");
  owner = (child_owner *)lua_newuserdatauv(L, sizeof(*owner), 0);
  owner->child = NULL;
  lua_newtable(L);
  lua_pushcfunction(L, child_gc); lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  owner->child = luaL_newstate();
  if (!owner->child) luaL_error(L, "scheduler child state allocation failed");
  child_call(L, owner->child, child_bootstrap);
  value = lua_totvalue(L, -1);
  lua_settop(L, top);
  return value;
}

void scheduler_child_check(lua_State *L, TValue value) {
  child_owner *owner = get_owner(L, value);
  if (!owner->child) luaL_error(L, "scheduler child is closed");
  child_call(L, owner->child, child_check);
}

void scheduler_close_child(lua_State *L, TValue value) {
  child_owner *owner = get_owner(L, value);
  if (owner->child) {
    lua_State *child = owner->child;
    owner->child = NULL;
    lua_close(child);
  }
}
