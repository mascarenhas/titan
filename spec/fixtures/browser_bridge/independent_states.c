#include <assert.h>
#include <limits.h>
#include <string.h>
#include <lauxlib.h>
#include <lualib.h>
#include <titan.h>
#include "../../stdlib/titan/browser/native.h"
#include "../browser_runtime/fixture_controls.h"

extern int luaopen_titan(lua_State *L);
extern int luaopen_browser_independent(lua_State *L);
extern void *titan_browser_\u2133_attach_titan(void *L);
extern void titan_browser_\u2133_close_state_titan(void *L);
typedef struct independent_owner { lua_State *child; } independent_owner;

/* Wrap titan_browser_host_identity_live in the dedicated bridge test image to
 * inject deterministic GC between result encoding and liveness validation. */
static lua_State *identity_gc_state;
static int identity_gc_after, identity_gc_running;
static titan_browser_state_record *admission_failure_record;
static uint32_t admission_failure_saved_token;
static int admission_failure_observed;

void titan_bridge_test_arm_identity_gc(lua_State *L, int after) {
  assert(identity_gc_state == NULL && after > 0);
  identity_gc_state = L;
  identity_gc_after = after;
  identity_gc_running = lua_gc(L, LUA_GCISRUNNING);
  lua_gc(L, LUA_GCSTOP);
}

void titan_bridge_test_arm_admission_failure(lua_State *L) {
  assert(admission_failure_record == NULL);
  admission_failure_record = (titan_browser_state_record *)titan_browser_\u2133_attach_titan(L);
  admission_failure_saved_token = admission_failure_record->token;
  admission_failure_record->token = 0;
  admission_failure_observed = 1;
}
int titan_bridge_test_finish_admission_failure(lua_State *L) {
  int observed = admission_failure_observed;
  (void)L;
  if (admission_failure_record) {
    admission_failure_record->token = admission_failure_saved_token;
    admission_failure_record = NULL;
  }
  admission_failure_observed = 0;
  return observed;
}
extern int __real_titan_browser_host_identity_live(uint32_t state,
    uint32_t slot, uint32_t generation, uint32_t kind);
int __wrap_titan_browser_host_identity_live(uint32_t state,
    uint32_t slot, uint32_t generation, uint32_t kind) {
  if (identity_gc_state && --identity_gc_after == 0) {
    lua_State *L = identity_gc_state;
    identity_gc_state = NULL;
    lua_gc(L, LUA_GCCOLLECT);
    if (identity_gc_running) lua_gc(L, LUA_GCRESTART);
  }
  return __real_titan_browser_host_identity_live(state, slot, generation, kind);
}

static struct {
  lua_State *L;
  lua_Alloc allocate;
  void *ud, *block;
  size_t old_size, size;
  int installed, armed, failures;
} response_failure;
static void restore_response_allocator(void) {
  if (response_failure.installed) {
    lua_setallocf(response_failure.L, response_failure.allocate, response_failure.ud);
    response_failure.installed = 0;
  }
}
static void *response_failure_allocate(void *ud, void *pointer, size_t old_size, size_t size) {
  (void)ud;
  if (response_failure.armed && size && (!pointer || size > old_size)) {
    if (!response_failure.failures) {
      response_failure.block = pointer;
      response_failure.old_size = old_size;
      response_failure.size = size;
    }
    if (pointer == response_failure.block && old_size == response_failure.old_size &&
        size == response_failure.size) {
      if (++response_failure.failures == 2) restore_response_allocator();
      return NULL; /* fail the actual allocation and emergency retry */
    }
  }
  return response_failure.allocate(response_failure.ud, pointer, old_size, size);
}
void titan_bridge_test_prepare_response_failure(lua_State *L) {
  assert(!response_failure.installed);
  memset(&response_failure, 0, sizeof(response_failure));
  response_failure.L = L;
  response_failure.allocate = lua_getallocf(L, &response_failure.ud);
  response_failure.installed = 1;
  lua_setallocf(L, response_failure_allocate, NULL);
}
__attribute__((used, visibility("default")))
void titan_bridge_test_arm_response_owner_failure(void) {
  assert(response_failure.installed);
  response_failure.armed = 1; /* pure C setter called by the owned message getter */
}
int titan_bridge_test_finish_response_failure(lua_State *L) {
  int failures = response_failure.failures;
  assert(response_failure.L == L);
  restore_response_allocator();
  memset(&response_failure, 0, sizeof(response_failure));
  return failures;
}

static struct {
  lua_State *L;
  lua_Alloc allocate;
  void *ud;
  int installed, after, failures;
} alloc_failure;
static void restore_alloc_failure(void) {
  if (alloc_failure.installed) {
    lua_setallocf(alloc_failure.L, alloc_failure.allocate, alloc_failure.ud);
    alloc_failure.installed = 0;
  }
}
static void *alloc_failure_allocate(void *ud, void *pointer, size_t old_size, size_t size) {
  (void)ud;
  if (alloc_failure.installed && size && (!pointer || size > old_size)) {
    if (alloc_failure.after > 0) {
      alloc_failure.after--;
    } else {
      if (++alloc_failure.failures >= 2) restore_alloc_failure();
      return NULL;
    }
  }
  return alloc_failure.allocate(alloc_failure.ud, pointer, old_size, size);
}
void titan_bridge_test_arm_alloc_failure(lua_State *L, int after) {
  assert(!alloc_failure.installed);
  memset(&alloc_failure, 0, sizeof(alloc_failure));
  alloc_failure.L = mainthread(G(L));
  alloc_failure.allocate = lua_getallocf(alloc_failure.L, &alloc_failure.ud);
  alloc_failure.after = after;
  alloc_failure.installed = 1;
  lua_setallocf(alloc_failure.L, alloc_failure_allocate, NULL);
}
int titan_bridge_test_finish_alloc_failure(lua_State *L) {
  int failures = alloc_failure.failures;
  assert(!alloc_failure.installed || alloc_failure.L == mainthread(G(L)));
  restore_alloc_failure();
  memset(&alloc_failure, 0, sizeof(alloc_failure));
  return failures;
}

static int error_tostring_ok(lua_State *L) {
  lua_pushliteral(L, "custom error tostring");
  return 1;
}
static int error_tostring_throw(lua_State *L) {
  return luaL_error(L, "converter boom");
}
static int inner_caught_worker(lua_State *L) {
  return luaL_error(L, "inner caught converter error");
}
static int error_tostring_catch_then_ok(lua_State *L) {
  lua_pushcfunction(L, errorhandler);
  lua_pushcfunction(L, inner_caught_worker);
  if (lua_pcall(L, 0, 0, -2) != LUA_OK) lua_pop(L, 2);
  lua_pushliteral(L, "converted after inner catch");
  return 1;
}
static int error_tostring_oom(lua_State *L) {
  titan_bridge_test_arm_alloc_failure(L, 0);
  lua_pushfstring(L, "uninterned error formatting allocation %p %d", (void *)L, 12345);
  return 1;
}
TValue titan_bridge_test_make_error_object(lua_State *L, int mode) {
  TValue result;
  int top = lua_gettop(L);
  luaL_checkstack(L, 4, "error object fixture");
  lua_newtable(L);
  lua_newtable(L);
  if (mode == 1) lua_pushcfunction(L, error_tostring_ok);
  else if (mode == 2) lua_pushcfunction(L, error_tostring_throw);
  else if (mode == 3) lua_pushcfunction(L, error_tostring_catch_then_ok);
  else lua_pushcfunction(L, error_tostring_oom);
  lua_setfield(L, -2, "__tostring");
  lua_setmetatable(L, -2);
  result = lua_totvalue(L, -1);
  lua_settop(L, top);
  return result;
}


static int owner_gc(lua_State *L) {
  independent_owner *owner = (independent_owner *)lua_touserdata(L, 1);
  if (owner->child) {
    lua_State *child = owner->child;
    owner->child = NULL;
    titan_browser_\u2133_close_state_titan(child);
  }
  return 0;
}
static int bootstrap(lua_State *L) {
  int index = (int)lua_tointeger(L, 1);
  titan_browser_\u2133_attach_titan(L); /* earliest finalized object, before openlibs */
  luaL_openlibs(L);
  titan_install_searcher(L);
  luaL_requiref(L, "titan", luaopen_titan, 0); lua_pop(L, 1);
  luaL_requiref(L, "browser.independent", luaopen_browser_independent, 0);
  lua_getfield(L, -1, index == 0 ? "publication" : "prepare");
  lua_pushinteger(L, index);
  lua_call(L, 1, 0);
  return 0;
}
static void protected_call(lua_State *parent, lua_State *child, lua_CFunction worker, int index) {
  int top = lua_gettop(child);
  if (!lua_checkstack(child, 5)) luaL_error(parent, "independent fixture stack allocation failed");
  lua_pushcfunction(child, errorhandler);
  lua_pushcfunction(child, worker);
  lua_pushinteger(child, index);
  if (lua_pcall(child, 1, 0, top + 1) != LUA_OK) {
    const char *message = lua_tostring(child, -1);
    lua_pushfstring(parent, "independent state fixture: %s", message ? message : "non-string failure");
    lua_settop(child, top);
    lua_error(parent);
  }
  lua_settop(child, top);
}
TValue titan_bridge_test_new_state(lua_State *L, int index) {
  independent_owner *owner;
  TValue value;
  int top = lua_gettop(L);
  luaL_checkstack(L, 4, "independent state owner");
  owner = (independent_owner *)lua_newuserdatauv(L, sizeof(*owner), 0);
  owner->child = NULL;
  lua_newtable(L);
  lua_pushcfunction(L, owner_gc); lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  owner->child = luaL_newstate();
  if (!owner->child) luaL_error(L, "independent state allocation failed");
  protected_call(L, owner->child, bootstrap, index);
  value = lua_totvalue(L, -1);
  lua_settop(L, top);
  return value;
}
static independent_owner *get_owner(lua_State *L, TValue value) {
  if (!ttisfulluserdata(&value)) luaL_error(L, "independent state owner is not userdata");
  return (independent_owner *)getudatamem(uvalue(&value));
}
void titan_bridge_test_close_state(lua_State *L, TValue value) {
  independent_owner *owner = get_owner(L, value);
  if (owner->child) {
    lua_State *child = owner->child;
    owner->child = NULL;
    /* External owners can call lua_close directly. The first bridge import
     * in a close-phase finalizer must detect GCSTPCLS before async admission. */
    lua_close(child);
  }
}
void *titan_bridge_test_detach_state(lua_State *L, TValue value) {
  independent_owner *owner = get_owner(L, value);
  lua_State *child = owner->child;
  owner->child = NULL;
  return child;
}
void titan_bridge_test_close_detached(void *state) {
  if (state) titan_browser_\u2133_close_state_titan((lua_State *)state);
}
static int check_worker(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, "browser.independent");
  lua_getfield(L, -1, "check"); lua_call(L, 0, 0);
  return 0;
}
void titan_bridge_test_check_state(lua_State *L, TValue value) {
  independent_owner *owner = get_owner(L, value);
  assert(owner->child);
  protected_call(L, owner->child, check_worker, 0);
}
