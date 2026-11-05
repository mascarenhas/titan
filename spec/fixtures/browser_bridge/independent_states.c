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

/* These controls wrap real Lua operations only in the dedicated native image.
 * Generation failure starts AFTER the strong reference has actually committed;
 * rollback is observed before restoring the still-failing allocator. */
static struct {
  lua_State *L;
  const void *roots;
  lua_Alloc allocate;
  void *ud;
  int armed, active, slot, observed;
} root_failure;
static lua_State *identity_gc_state, *admission_failure_state;
static int identity_gc_after, identity_gc_running, admission_failure_observed;

static void *root_failure_allocate(void *ud, void *pointer, size_t old_size, size_t size) {
  (void)ud;
  if (size && (!pointer || size > old_size)) {
    root_failure.observed |= 4;
    return NULL;
  }
  return root_failure.allocate(root_failure.ud, pointer, old_size, size);
}
static void restore_root_allocator(void) {
  if (root_failure.active) {
    lua_setallocf(root_failure.L, root_failure.allocate, root_failure.ud);
    root_failure.active = 0;
  }
}
extern int __real_luaL_ref(lua_State *L, int table);
int __wrap_luaL_ref(lua_State *L, int table) {
  int reference = __real_luaL_ref(L, table);
  if (root_failure.armed && L == root_failure.L) {
    assert(reference > 0);
    root_failure.armed = 0;
    root_failure.slot = reference;
    root_failure.roots = lua_topointer(L, table);
    root_failure.observed |= 1;
    root_failure.allocate = lua_getallocf(L, &root_failure.ud);
    root_failure.active = 1;
    lua_setallocf(L, root_failure_allocate, NULL);
  }
  return reference;
}
extern void __real_lua_rawseti(lua_State *L, int table, lua_Integer key);
void __wrap_lua_rawseti(lua_State *L, int table, lua_Integer key) {
  if (root_failure.active && L == root_failure.L && key == root_failure.slot &&
      lua_topointer(L, table) != root_failure.roots)
    root_failure.observed |= 2;
  __real_lua_rawseti(L, table, key);
}
extern void __real_luaL_unref(lua_State *L, int table, int reference);
void __wrap_luaL_unref(lua_State *L, int table, int reference) {
  int rollback = root_failure.active && L == root_failure.L &&
      reference == root_failure.slot && lua_topointer(L, table) == root_failure.roots;
  __real_luaL_unref(L, table, reference);
  if (rollback) {
    root_failure.observed |= 8;
    restore_root_allocator();
  }
}
void titan_bridge_test_arm_generation_failure(lua_State *L) {
  assert(!root_failure.active && !root_failure.armed);
  memset(&root_failure, 0, sizeof(root_failure));
  root_failure.L = L;
  root_failure.armed = 1;
}
int titan_bridge_test_finish_generation_failure(lua_State *L) {
  int observed = root_failure.observed;
  assert(root_failure.L == L);
  restore_root_allocator();
  memset(&root_failure, 0, sizeof(root_failure));
  return observed;
}

void titan_bridge_test_arm_identity_gc(lua_State *L, int after) {
  assert(identity_gc_state == NULL && after > 0);
  identity_gc_state = L;
  identity_gc_after = after;
  identity_gc_running = lua_gc(L, LUA_GCISRUNNING);
  lua_gc(L, LUA_GCSTOP);
}
extern void __real_lua_callk(lua_State *L, int arguments, int results,
    lua_KContext context, lua_KFunction continuation);
void __wrap_lua_callk(lua_State *L, int arguments, int results,
    lua_KContext context, lua_KFunction continuation) {
  if (L == identity_gc_state && arguments == 1 && results == 2 &&
      --identity_gc_after == 0) {
    identity_gc_state = NULL;
    lua_gc(L, LUA_GCCOLLECT);
    if (identity_gc_running) lua_gc(L, LUA_GCRESTART);
  }
  __real_lua_callk(L, arguments, results, context, continuation);
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
extern void __real_luaL_checkstack(lua_State *L, int size, const char *message);
void __wrap_luaL_checkstack(lua_State *L, int size, const char *message) {
  if (L == admission_failure_state && message && !strcmp(message, "browser state identity")) {
    admission_failure_state = NULL;
    admission_failure_observed = 1;
    /* Exercise the actual Lua stack-limit refusal, not a fake bridge error.
     * luaD_growstack checks n against its limit before adding, so INT_MAX
     * cannot overflow its requested-size arithmetic. */
    __real_luaL_checkstack(L, INT_MAX, message);
  }
  __real_luaL_checkstack(L, size, message);
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

static int raw_callback(lua_State *L) { (void)L; return 0; }
TValue titan_bridge_test_c_function(lua_State *L) {
  TValue value;
  int top = lua_gettop(L);
  luaL_checkstack(L, 1, "bridge C function fixture");
  lua_pushcfunction(L, raw_callback);
  value = lua_totvalue(L, -1);
  lua_settop(L, top);
  return value;
}
TValue titan_bridge_test_lua_function(lua_State *L) {
  TValue value;
  int top = lua_gettop(L);
  static const char source[] = "return function(x) return x end";
  luaL_checkstack(L, 2, "bridge Lua function fixture");
  if (luaL_loadbuffer(L, source, sizeof(source) - 1, "@bridge-lua-function") != LUA_OK)
    lua_error(L);
  lua_call(L, 0, 1);
  value = lua_totvalue(L, -1);
  lua_settop(L, top);
  return value;
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

static titan_browser_identity callback_root(lua_State *L, TValue callback,
    uint32_t count, const uint32_t *kinds) {
  titan_browser_identity identity;
  titan_browser_signature signature = {count, 0, kinds, NULL};
  titan_browser_root_callable(L, callback, &signature, &identity);
  return identity;
}
static void io_admitted(lua_State *L, titan_browser_response *response) {
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
  static const uint32_t bytes_kind[] = {TITAN_BROWSER_BYTES};
  static const uint32_t failure_kinds[] = {TITAN_BROWSER_BYTES, TITAN_BROWSER_HANDLE};
  io_context *context = (io_context *)lua_touserdata(L, 1);
  titan_browser_response response = {0};
  context->done = callback_root(L, lua_totvalue(L, 2), context->read ? 1 : 0,
      context->read ? bytes_kind : NULL);
  context->failed = callback_root(L, lua_totvalue(L, 3), 2, failure_kinds);
  if (context->read) {
    titan_browser_host_read(titan_browser_state(L), context->length,
        context->done.slot, context->done.generation,
        context->failed.slot, context->failed.generation, &response);
  } else {
    titan_browser_host_write(titan_browser_state(L), TITAN_BROWSER_STDOUT,
        context->bytes, context->length, context->done.slot, context->done.generation,
        context->failed.slot, context->failed.generation, &response);
  }
  io_admitted(L, &response);
  return 0;
}
static void io_request(lua_State *L, TValue success, TValue failure, io_context *context) {
  int top = lua_gettop(L);
  luaL_checkstack(L, 12, "SDK callback root transaction");
  lua_pushcfunction(L, io_worker);
  lua_pushlightuserdata(L, context);
  lua_pushtvalue(L, success);
  lua_pushtvalue(L, failure);
  if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
    /* Both drops use only the reservation above. A failed second root or
     * host admission never leaves an unpublished pair owned until disposal. */
    if (context->done.slot) titan_browser_drop_callable(L, &context->done);
    if (context->failed.slot) titan_browser_drop_callable(L, &context->failed);
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
