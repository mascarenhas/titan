/* Child-only GNU ld --wrap boundary over the unchanged public UV provider.
 * No libuv header or layout is imported. On the Linux-only injection lane,
 * libuv's uv_mutex_t and uv_thread_t are pthread_mutex_t and pthread_t.
 * The mutex-init and thread-retirement wrappers retain these exact pointer
 * types. Lua allocator traffic is bypassed for allocation injection; native
 * retirement errors are armed only around one valid caller-owned token. */
#include "uv_sync_alloc_fault_api.h"
#include <errno.h>
#include <stdlib.h>

#if defined(__linux__)
#include <pthread.h>

void *__real_malloc(size_t size);
void __real_free(void *pointer);
int __real_uv_mutex_init(pthread_mutex_t *mutex);
int __real_uv_thread_join(pthread_t *thread);
int __real_uv_thread_detach(pthread_t *thread);
int __real_uv_thread_create(pthread_t *thread, void (*entry)(void *), void *argument);

static lua_Alloc original_allocator;
static void *original_allocator_data;
static int in_lua_allocator;
static int armed_mode;
static void *candidate;
static int allocations;
static int initializations;
static int failures;
static int frees;
static int thread_mode;
static void *thread_candidate;
static int thread_failures;
static int thread_frees;
static int thread_allocations;
static int thread_creations;

static void *lua_allocator(void *data, void *pointer, size_t old_size,
                           size_t new_size) {
  void *result;
  (void)data;
  in_lua_allocator++;
  result = original_allocator(original_allocator_data, pointer, old_size, new_size);
  in_lua_allocator--;
  return result;
}

int titan_uv_mutex_fault_install(lua_State *state) {
  if (original_allocator != NULL) return 0;
  original_allocator = lua_getallocf(state, &original_allocator_data);
  if (original_allocator == NULL) return 0;
  lua_setallocf(state, lua_allocator, NULL);
  return 1;
}

void titan_uv_mutex_fault_restore(lua_State *state) {
  armed_mode = 0;
  thread_mode = 0;
  if (original_allocator != NULL) {
    lua_setallocf(state, original_allocator, original_allocator_data);
    original_allocator = NULL;
    original_allocator_data = NULL;
  }
}

void titan_uv_mutex_fault_arm(int mode) {
  armed_mode = mode;
  candidate = NULL;
  allocations = 0;
  initializations = 0;
  failures = 0;
  frees = 0;
}

void titan_uv_mutex_fault_disarm(void) { armed_mode = 0; }
int titan_uv_mutex_fault_allocations(void) { return allocations; }
int titan_uv_mutex_fault_initializations(void) { return initializations; }
int titan_uv_mutex_fault_failures(void) { return failures; }
int titan_uv_mutex_fault_frees(void) { return frees; }

void titan_uv_thread_fault_arm(int mode) {
  thread_mode = mode;
  thread_candidate = NULL;
  thread_failures = 0;
  thread_frees = 0;
  thread_allocations = 0;
  thread_creations = 0;
}
void titan_uv_thread_fault_disarm(void) { thread_mode = 0; }
int titan_uv_thread_fault_failures(void) { return thread_failures; }
int titan_uv_thread_fault_frees(void) { return thread_frees; }
int titan_uv_thread_fault_allocations(void) { return thread_allocations; }
int titan_uv_thread_fault_creations(void) { return thread_creations; }
void titan_uv_thread_fault_worker(void *argument) { (void)argument; }

int __wrap_uv_thread_join(pthread_t *thread) {
  if (thread_mode == 1) {
    thread_mode = 0;
    thread_candidate = thread;
    thread_failures++;
    return -EBUSY;
  }
  return __real_uv_thread_join(thread);
}

int __wrap_uv_thread_detach(pthread_t *thread) {
  if (thread_mode == 2) {
    thread_mode = 0;
    thread_candidate = thread;
    thread_failures++;
    return -EBUSY;
  }
  return __real_uv_thread_detach(thread);
}

int __wrap_uv_thread_create(pthread_t *thread, void (*entry)(void *),
                            void *argument) {
  if (thread_mode == 4 && thread == thread_candidate) {
    thread_mode = 0;
    thread_creations++;
    thread_failures++;
    return -EAGAIN;
  }
  return __real_uv_thread_create(thread, entry, argument);
}

void *__wrap_malloc(size_t size) {
  if (!in_lua_allocator && (thread_mode == 3 || thread_mode == 4) &&
      size == sizeof(pthread_t)) {
    thread_allocations++;
    if (thread_mode == 3) {
      thread_mode = 0;
      thread_failures++;
      errno = ENOMEM;
      return NULL;
    }
    thread_candidate = __real_malloc(size);
    return thread_candidate;
  }
  if (!in_lua_allocator && armed_mode && size == sizeof(pthread_mutex_t)) {
    allocations++;
    if (armed_mode == 1) {
      armed_mode = 0;
      failures++;
      errno = ENOMEM;
      return NULL;
    }
    candidate = __real_malloc(size);
    return candidate;
  }
  return __real_malloc(size);
}

int __wrap_uv_mutex_init(pthread_mutex_t *mutex) {
  if (armed_mode && mutex == candidate && candidate != NULL) {
    int mode = armed_mode;
    armed_mode = 0;
    initializations++;
    if (mode == 2) {
      failures++;
      return -ENOMEM;
    }
  }
  return __real_uv_mutex_init(mutex);
}

void __wrap_free(void *pointer) {
  if (candidate != NULL && pointer == candidate) {
    candidate = NULL;
    frees++;
  }
  if (thread_candidate != NULL && pointer == thread_candidate) {
    thread_candidate = NULL;
    thread_frees++;
  }
  __real_free(pointer);
}
#else
/* The native parent skips this injection mechanism outside Linux. */
int titan_uv_mutex_fault_unsupported_host;
#endif
