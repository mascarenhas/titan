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
typedef struct independent_owner { lua_State *child; } independent_owner;

/* Wrap titan_browser_state in the dedicated bridge test image to inject
 * deterministic GC during result encoding and close-time state failures. */
static lua_State *identity_gc_state, *admission_failure_state;
static int identity_gc_after, identity_gc_running, admission_failure_observed;

void titan_bridge_test_arm_identity_gc(lua_State *L, int after) {
  assert(identity_gc_state == NULL && after > 0);
  identity_gc_state = L;
  identity_gc_after = after;
  identity_gc_running = lua_gc(L, LUA_GCISRUNNING);
  lua_gc(L, LUA_GCSTOP);
}

void titan_bridge_test_arm_admission_failure(lua_State *L) {
  assert(admission_failure_state == NULL);
  admission_failure_state = L;
  admission_failure_observed = 0;
}
int titan_bridge_test_finish_admission_failure(lua_State *L) {
  assert(admission_failure_state == NULL || admission_failure_state == L);
  admission_failure_state = NULL;
  return admission_failure_observed;
}
extern uint32_t __real_titan_browser_state(lua_State *L);
uint32_t __wrap_titan_browser_state(lua_State *L) {
  if (L == admission_failure_state) {
    admission_failure_state = NULL;
    admission_failure_observed = 1;
    luaL_error(L, "browser state admission failure");
  }
  if (L == identity_gc_state && --identity_gc_after == 0) {
    identity_gc_state = NULL;
    lua_gc(L, LUA_GCCOLLECT);
    if (identity_gc_running) lua_gc(L, LUA_GCRESTART);
  }
  return __real_titan_browser_state(L);
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


static int owner_gc(lua_State *L) {
  independent_owner *owner = (independent_owner *)lua_touserdata(L, 1);
  if (owner->child) {
    lua_State *child = owner->child;
    owner->child = NULL;
    titan_browser_close_state(child);
  }
  return 0;
}
static int bootstrap(lua_State *L) {
  int index = (int)lua_tointeger(L, 1);
  titan_browser_attach(L); /* earliest finalized object, before openlibs */
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
  if (state) titan_browser_close_state((lua_State *)state);
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

static void io_admitted(lua_State *L, titan_browser_response *response,
    titan_browser_identity *done, titan_browser_identity *failed) {
  uint32_t status = response->status;
  /* The SDK C caller owns this request unit until its terminal notification;
   * state-wide retirement covers an interrupted test. No borrowed data stays. */
  if (status == TITAN_BROWSER_OK) {
    assert(response->value.kind == TITAN_BROWSER_REQUEST);
    assert(!titan_browser_host_identity_live(response->state, response->value.slot,
        response->value.generation, TITAN_BROWSER_HANDLE));
    assert(!titan_browser_host_identity_live(response->state, response->value.slot,
        response->value.generation, TITAN_BROWSER_REQUEST));
    response->value.slot = 0;
  } else {
    if (done->slot) { titan_browser_unpin_callable(L, done); done->slot = 0; }
    if (failed->slot) { titan_browser_unpin_callable(L, failed); failed->slot = 0; }
  }
  titan_browser_response_dispose(response);
  if (status != TITAN_BROWSER_OK) luaL_error(L, "SDK byte I/O fixture admission failed");
}
typedef struct io_context {
  int read;
  uint32_t length;
  const unsigned char *bytes;
  titan_browser_identity done, failed;
} io_context;
static int io_worker(lua_State *L) {
  io_context *context = (io_context *)lua_touserdata(L, 1);
  titan_browser_response response = {0};
  titan_browser_pin_callable(L, lua_totvalue(L, 2), &context->done);
  titan_browser_pin_callable(L, lua_totvalue(L, 3), &context->failed);
  if (context->read) {
    titan_browser_host_read(titan_browser_state(L), context->length,
        context->done.slot, context->done.generation,
        context->failed.slot, context->failed.generation, &response);
  } else {
    titan_browser_host_write(titan_browser_state(L), TITAN_BROWSER_STDOUT,
        context->bytes, context->length, context->done.slot, context->done.generation,
        context->failed.slot, context->failed.generation, &response);
  }
  io_admitted(L, &response, &context->done, &context->failed);
  return 0;
}
static void io_request(lua_State *L, TValue success, TValue failure, io_context *context) {
  int top = lua_gettop(L);
  luaL_checkstack(L, 12, "SDK callback pin transaction");
  lua_pushcfunction(L, io_worker);
  lua_pushlightuserdata(L, context);
  lua_pushtvalue(L, success);
  lua_pushtvalue(L, failure);
  if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
    if (context->done.slot) titan_browser_unpin_callable(L, &context->done);
    if (context->failed.slot) titan_browser_unpin_callable(L, &context->failed);
    lua_error(L);
  }
  lua_settop(L, top);
}
void titan_bridge_test_write(lua_State *L, TValue success, TValue failure,
    const unsigned char *bytes, uint32_t length) {
  io_context context = {0, length, bytes, {0}, {0}};
  io_request(L, success, failure, &context);
}
void titan_bridge_test_read(lua_State *L, TValue success, TValue failure, uint32_t capacity) {
  io_context context = {1, capacity, NULL, {0}, {0}};
  io_request(L, success, failure, &context);
}
