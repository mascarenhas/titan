/* GNU ld --wrap is deliberately child-only: the canonical production archive
 * is linked unchanged. Lua-managed allocations use their original allocator
 * under a bypass, so a Lua allocation cannot impersonate the native boundary.
 * Armed code is synchronous public transfer encoding/adoption. No background
 * Tasks, process-global allocator replacement, or copied production source. */
#include "transfer_alloc_fault_api.h"
#include "transfer_native.h"
#include "lauxlib.h"
#include <errno.h>
#include <stdlib.h>

#if defined(__linux__)
void *__real_malloc(size_t size);
void *__real_calloc(size_t count, size_t size);
void *__real_realloc(void *pointer, size_t size);
int __real_lua_setmetatable(lua_State *state, int index);

static lua_Alloc original_allocator;
static void *original_allocator_data;
static int in_lua_allocator;
static int armed_mode;
static const void *finalizer_metatable;
static int failures;
static int failed_allocator;
static size_t failed_retains;
static size_t failed_releases;
/* Static native owners survive even a failing test's lua_close. */
static titan_transfer_fault_resource resources[2] = {
  {1, 0, 0, 0}, {1, 0, 0, 0}
};

static void *lua_allocator(void *data, void *pointer, size_t old_size,
                           size_t new_size) {
  void *result;
  (void)data;
  in_lua_allocator++;
  result = original_allocator(original_allocator_data, pointer, old_size, new_size);
  in_lua_allocator--;
  return result;
}

int titan_transfer_fault_install(lua_State *state) {
  if (original_allocator != NULL) return 0;
  original_allocator = lua_getallocf(state, &original_allocator_data);
  if (original_allocator == NULL) return 0;
  lua_setallocf(state, lua_allocator, NULL);
  return 1;
}

void titan_transfer_fault_restore(lua_State *state) {
  armed_mode = 0;
  if (original_allocator != NULL) {
    lua_setallocf(state, original_allocator, original_allocator_data);
    original_allocator = NULL;
    original_allocator_data = NULL;
  }
}

int titan_transfer_fault_watch_finalizer(lua_State *state, int index) {
  int top = lua_gettop(state);
  if (!lua_checkstack(state, 1) || !lua_getmetatable(state, index)) return 0;
  finalizer_metatable = lua_topointer(state, -1);
  lua_settop(state, top);
  return finalizer_metatable != NULL;
}

size_t titan_transfer_fault_inline_resources(void) {
  return TITAN_TRANSFER_INLINE_RESOURCES;
}

titan_transfer_fault_resource *titan_transfer_fault_resource_at(unsigned int index) {
  return index < 2 ? &resources[index] : NULL;
}

void titan_transfer_fault_retain(void *raw) {
  titan_transfer_fault_resource *resource = raw;
  resource->references++;
  resource->retains++;
}

void titan_transfer_fault_release(void *raw) {
  titan_transfer_fault_resource *resource = raw;
  if (resource->references <= 1) resource->invalid_release = 1;
  else resource->references--;
  resource->releases++;
}

void titan_transfer_fault_arm(int mode) {
  armed_mode = mode;
  failures = 0;
  failed_allocator = 0;
  failed_retains = 0;
  failed_releases = 0;
}

void titan_transfer_fault_disarm(void) { armed_mode = 0; }
int titan_transfer_fault_fired(void) { return failures; }
int titan_transfer_fault_allocator(void) { return failed_allocator; }
size_t titan_transfer_fault_retains_at_failure(void) { return failed_retains; }
size_t titan_transfer_fault_releases_at_failure(void) { return failed_releases; }

static int fail_allocation(int allocator, void *pointer, size_t size) {
  int matches = 0;
  if (in_lua_allocator || !armed_mode) return 0;
  if (armed_mode == 1) {
    /* The first spill doubles the inline capacity with a fresh malloc. */
    matches = pointer == NULL &&
      size == 2 * TITAN_TRANSFER_INLINE_RESOURCES * sizeof(titan_transfer_resource);
  } else if (armed_mode == 2) {
    /* The next growth doubles that spill in place with realloc. */
    matches = pointer != NULL &&
      size == 4 * TITAN_TRANSFER_INLINE_RESOURCES * sizeof(titan_transfer_resource);
  } else if (armed_mode == 3) {
    matches = (allocator == 1 || allocator == 2) &&
      size >= sizeof(titan_async_message);
  } else if (armed_mode == 4) {
    matches = pointer == NULL && size >= sizeof(titan_async_message);
  } else if (armed_mode == 5) {
    matches = allocator == 3 && pointer != NULL;
  }
  if (!matches) return 0;
  armed_mode = 0; /* Errors/rollback are never poisoned by the injection. */
  failures++;
  failed_allocator = allocator;
  failed_retains = resources[0].retains + resources[1].retains;
  failed_releases = resources[0].releases + resources[1].releases;
  errno = ENOMEM;
  return 1;
}

void *__wrap_malloc(size_t size) {
  if (fail_allocation(1, NULL, size)) return NULL;
  return __real_malloc(size);
}

void *__wrap_calloc(size_t count, size_t size) {
  if (size != 0 && count <= SIZE_MAX / size &&
      fail_allocation(2, NULL, count * size)) return NULL;
  return __real_calloc(count, size);
}

void *__wrap_realloc(void *pointer, size_t size) {
  if (fail_allocation(3, pointer, size)) return NULL;
  return __real_realloc(pointer, size);
}

int __wrap_lua_setmetatable(lua_State *state, int index) {
  /* Generated nominal construction assigns Udata.metatable directly. Only
   * gc.finalizable re-installs it through this public Lua API, after the inert
   * endpoint wrapper exists and before claim_resource can commit adoption. */
  if (armed_mode == 6 && finalizer_metatable != NULL &&
      lua_type(state, index) == LUA_TUSERDATA &&
      lua_topointer(state, -1) == finalizer_metatable) {
    armed_mode = 0;
    failures++;
    return luaL_error(state, "owned-finalizer-registration-fault");
  }
  return __real_lua_setmetatable(state, index);
}
#else
/* The native parent classifies this mechanism as Linux-only before linking. */
int titan_transfer_fault_unsupported_host;
#endif
