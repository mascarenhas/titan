#include <emscripten.h>
#include <stdint.h>
#include <stdlib.h>
#include <lauxlib.h>
#include <lualib.h>
#include <titan.h>
#include "mini_driver.h"

extern int luaopen_titan(lua_State *L);
extern int luaopen_mini_child(lua_State *L);

/* A synchronous C callback, the way an Emscripten API makes one: JavaScript
 * calls this function through the Wasm table and it calls the pinned
 * callable through titan_browser_call_sync. */
static int mini_driver_fire(uint32_t state, uint32_t slot, uint32_t generation) {
  titan_browser_identity identity = {state, slot, generation};
  titan_browser_sync_result result = {0};
  int status = titan_browser_call_sync(&identity, 0, NULL, &result);
  free((void *)result.message);
  free((void *)result.trace);
  if (result.value.kind == TITAN_BROWSER_STRING || result.value.kind == TITAN_BROWSER_BYTES)
    free((void *)result.value.bytes);
  return status;
}

/* Loader observations for the harness, published only to its explicit
 * __miniDriver binding; generated images never expose the Module. `allocate`
 * calls the plain _malloc/_free exports, which no admission gate guards.
 * `fire` makes a synchronous C callback; `hooks.poke` is what
 * mini_driver_poke calls, JavaScript reached from C without a binding. */
EM_JS_DEPS(mini_driver, "$getWasmTableEntry");
EM_JS(void, mini_driver_controls, (int fire), {
  var owner = Module['titanBrowserBridge'];
  var publish = owner.options.bindings?.__miniDriver;
  if (!publish) return;
  var hooks = Module['miniDriverHooks'] = {poke: undefined};
  publish(Object.freeze({
    snapshot: () => Object.freeze({driving: !!owner.drive, parked: !!owner.drive?.gate,
      queue: owner.queue.length, batch: owner.batch.length,
      settling: owner.settling.length, requests: owner.requests.size, inHost: owner.inHost,
      ownerState: owner.ownerState, exited: owner.exited ? owner.exited.status : null,
      operationId: owner.operationId, active: !!owner.active, turnScheduled: !!owner.turnScheduled}),
    allocate: () => {
      var pointer = Module['_malloc'](16);
      Module['_free'](pointer);
      return pointer !== 0;
    },
    fire: (state, slot, generation) => getWasmTableEntry(fire)(state, slot, generation),
    hooks,
  }));
});

EM_JS(void, mini_driver_poke, (), {
  Module['miniDriverHooks']?.poke?.();
});

void mini_driver_publish_controls(void) {
  mini_driver_controls((int)(intptr_t)mini_driver_fire);
}

/* Authored C that switches stacks inside a synchronous callback. */
int mini_driver_switch(uint32_t state) {
  return (int)titan_browser_relinquish(state, TITAN_BROWSER_TURN);
}

/* A C-created child state never owns the instance. */
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
  luaL_requiref(L, "mini_child", luaopen_mini_child, 0);
  lua_getfield(L, -1, "publication");
  lua_call(L, 0, 0);
  return 0;
}

TValue mini_driver_new_child(lua_State *L) {
  child_owner *owner;
  lua_State *child;
  TValue value;
  int top = lua_gettop(L);
  luaL_checkstack(L, 4, "mini driver child owner");
  owner = (child_owner *)lua_newuserdatauv(L, sizeof(*owner), 0);
  owner->child = NULL;
  lua_newtable(L);
  lua_pushcfunction(L, child_gc); lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  child = owner->child = luaL_newstate();
  if (!child) luaL_error(L, "mini driver child state allocation failed");
  if (!lua_checkstack(child, 3)) luaL_error(L, "mini driver child stack allocation failed");
  lua_pushcfunction(child, errorhandler);
  lua_pushcfunction(child, child_bootstrap);
  if (lua_pcall(child, 0, 0, 1) != LUA_OK) {
    const char *message = lua_tostring(child, -1);
    lua_pushfstring(L, "mini driver child: %s", message ? message : "non-string failure");
    lua_error(L);
  }
  lua_settop(child, 0);
  value = lua_totvalue(L, -1);
  lua_settop(L, top);
  return value;
}

/* A checked C-stack overflow: each frame takes 64 KiB of the linear stack,
 * so Emscripten's stack check aborts long before the engine stack fills. */
static int __attribute__((noinline)) overflow(volatile unsigned char *previous) {
  volatile unsigned char frame[65536];
  frame[0] = (unsigned char)(previous ? previous[0] + 1 : 1);
  return overflow(frame) + frame[0];
}

int mini_driver_overflow(void) { return overflow(NULL); }
