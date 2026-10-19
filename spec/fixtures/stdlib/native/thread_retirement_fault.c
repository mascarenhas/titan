/* Linux fresh-child interposition only. The linked Titan/Lua archives and
 * their sources are unchanged. Real worker entry, OS exit and successful join
 * remain distinct events; only __real_uv_thread_join returning zero counts.
 * Lua faults are real allocator rejections at natural stack growth, an armed
 * userdata constructor, or public listener/Map allocation boundaries observed
 * through ordinary API calls. No Lua stack metadata or Task slots are changed. */
#include "thread_retirement_fault_api.h"
#include "uv.h"
#include "lstate.h"
#include "lobject.h"
#include "lstring.h"
#include "ldo.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
int __real_uv_thread_create(uv_thread_t *, uv_thread_cb, void *);
int __real_uv_thread_join(uv_thread_t *);
int __real_luaD_growstack(lua_State *, int, int);
Udata *__real_luaS_newudata(lua_State *, size_t, unsigned short);
CClosure *__real_luaF_newCclosure(lua_State *, int);
void __real_luaH_set(lua_State *, Table *, const TValue *, TValue *);
void *__real_malloc(size_t);

typedef struct thread_fault_domain {
  uv_mutex_t mutex;
  uv_sem_t events;
  uv_sem_t started;
  uv_sem_t cleanup_entered;
  uv_sem_t cleanup_release;
  uv_sem_t exit_release;
  uv_sem_t native_release;
  uv_sem_t entry_release;
  uv_sem_t entry_completed;
  uv_thread_t witness;
  uv_thread_t host;
  uv_thread_t worker;
  uv_thread_t direct_worker;
  int witness_started;
  int capture_next;
  int created;
  int gate_entry;
  int entry_released;
  int finish_before_create_return;
  int child_started;
  int child_cleanup;
  int cleanup_released;
  int entry_returned;
  int tail_released;
  int real_join_requested;
  int join_attempts;
  int join_failures;
  int real_joins;
  int terminals;
  int early_terminals;
  int changed_token;
  void *first_join_token;
  int fail_join;
  int aborting;
  int native_finished;
  int native_released;
  void *wake_target;
  void (*wake_retain)(void *);
  int (*wake_notify)(void *);
  void (*wake_release)(void *);
  /* These fields are used exclusively on the owning Lua OS thread. Neither
   * native worker nor witness reads a Lua pointer, allocator or GC object. */
  global_State *host_global;
  lua_State *fault_thread;
  void *fault_stack;
  lua_Alloc allocator;
  void *allocator_data;
  lua_State *allocator_thread;
  int allocator_installed;
  int allocator_budget;
  size_t userdata_size;
  int userdata_armed;
  int stack_growth;
  int allocator_hits;
  int userdata_entry;
  int allocation_bytes;
  int wide_body;
  int forward_hook;
  int packet_probe;
  void *packet_probe_pointer;
  void *packet_probe_caller;
  void *packet_copy_caller;
  int packet_copy_armed;
  int packet_copy_failures;
  int listener_probe;
  void *listener_return_caller;
  void *listener_registration_caller;
  int listener_return_armed;
  int listener_registration_armed;
  int listener_return_failures;
  int listener_registration_failures;
  int map_probe;
  Table *map_thread_metatable;
  int map_admission_armed;
  int map_admission_failures;
  int fail_create;
  int create_failures;
} thread_fault_domain;

typedef struct thread_fault_start {
  thread_fault_domain *domain;
  uv_thread_cb entry;
  void *argument;
} thread_fault_start;

static thread_fault_domain *domain;

static int on_host(thread_fault_domain *state) {
  uv_thread_t current = uv_thread_self();
  return uv_thread_equal(&state->host, &current);
}

/* Learn the real packet allocator from a returned public encode_message owner.
 * Only that callsite may fail later; Lua allocation and error rendering remain
 * untouched, and no production layout, symbol name, or slot count is guessed. */
void *__wrap_malloc(size_t size) {
  thread_fault_domain *state = domain;
  void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
  void *result;
  int selected = state && on_host(state);
  if (selected && state->packet_copy_armed &&
      caller == state->packet_copy_caller) {
    state->packet_copy_armed = 0;
    state->packet_copy_failures++;
    state->allocation_bytes = size > INT_MAX ? INT_MAX : (int)size;
    errno = ENOMEM;
    return NULL;
  }
  result = __real_malloc(size);
  if (selected && state->packet_probe) {
    state->packet_probe_pointer = result;
    state->packet_probe_caller = caller;
  }
  return result;
}

static void signal_event(thread_fault_domain *state) {
  uv_sem_post(&state->events);
}

static void witness_main(void *argument) {
  thread_fault_domain *state = argument;
  for (;;) {
    int release_tail = 0;
    uv_sem_wait(&state->events);
    uv_mutex_lock(&state->mutex);
    if (state->entry_returned && !state->tail_released &&
        (state->real_join_requested || state->terminals || state->aborting)) {
      state->tail_released = 1;
      release_tail = 1;
    }
    uv_mutex_unlock(&state->mutex);
    if (release_tail) {
      uv_sem_post(&state->exit_release);
      return;
    }
  }
}

static void worker_trampoline(void *argument) {
  thread_fault_start *start = argument;
  thread_fault_domain *state = start->domain;
  uv_thread_cb entry = start->entry;
  void *payload = start->argument;
  free(start);
  uv_mutex_lock(&state->mutex);
  int gated = state->gate_entry;
  uv_mutex_unlock(&state->mutex);
  if (gated) {
    /* Signal the native entry gate, not execution of the child's Task body. */
    uv_sem_post(&state->started);
    uv_sem_wait(&state->entry_release);
  }
  entry(payload); /* includes unchanged production ctrl.finished publication */
  uv_mutex_lock(&state->mutex);
  state->entry_returned = 1;
  uv_mutex_unlock(&state->mutex);
  uv_sem_post(&state->entry_completed);
  signal_event(state);
  /* The production callback has returned, but this real OS worker has not.
   * The independent witness can release it while the host blocks in join. */
  uv_sem_wait(&state->exit_release);
}

int __wrap_uv_thread_create(uv_thread_t *thread, uv_thread_cb entry, void *argument) {
  thread_fault_domain *state = domain;
  thread_fault_start *start;
  int capture = 0;
  int fail = 0;
  int wait_finished = 0;
  int status;
  if (state && on_host(state)) {
    uv_mutex_lock(&state->mutex);
    capture = state->capture_next;
    state->capture_next = 0;
    fail = state->fail_create;
    state->fail_create = 0;
    if (fail) state->create_failures++;
    uv_mutex_unlock(&state->mutex);
  }
  if (fail) return UV_EAGAIN;
  if (!capture) return __real_uv_thread_create(thread, entry, argument);
  start = malloc(sizeof(*start));
  if (!start) return UV_ENOMEM;
  start->domain = state;
  start->entry = entry;
  start->argument = argument;
  status = __real_uv_thread_create(thread, worker_trampoline, start);
  if (status) {
    free(start);
    return status;
  }
  uv_mutex_lock(&state->mutex);
  state->worker = *thread;
  state->created++;
  wait_finished = state->finish_before_create_return;
  uv_mutex_unlock(&state->mutex);
  /* The selected child has no host-loop dependency in this mode. Waiting for
   * its actual callback return makes ctrl.finished precede Group observation,
   * while the independent witness still holds the real OS exit tail. */
  if (wait_finished) uv_sem_wait(&state->entry_completed);
  return 0;
}

int __wrap_uv_thread_join(uv_thread_t *thread) {
  thread_fault_domain *state = domain;
  int selected = 0;
  int fail = 0;
  int status;
  if (state && on_host(state)) {
    uv_mutex_lock(&state->mutex);
    if (state->created && !state->real_joins)
      selected = uv_thread_equal(thread, &state->worker);
    if (selected) {
      state->join_attempts++;
      if (state->first_join_token && state->first_join_token != thread)
        state->changed_token++;
      if (!state->first_join_token) state->first_join_token = thread;
      fail = state->fail_join;
      state->fail_join = 0;
      if (fail) state->join_failures++;
      else state->real_join_requested = 1;
    }
    uv_mutex_unlock(&state->mutex);
  }
  if (!selected) return __real_uv_thread_join(thread);
  signal_event(state);
  if (fail) return UV_EAGAIN; /* token untouched, real join not called */
  status = __real_uv_thread_join(thread);
  if (status == 0) {
    uv_mutex_lock(&state->mutex);
    state->real_joins++;
    uv_mutex_unlock(&state->mutex);
  }
  return status;
}

static void restore_allocator(thread_fault_domain *state) {
  if (!state->allocator_installed) return;
  lua_setallocf(state->allocator_thread, state->allocator, state->allocator_data);
  state->allocator_thread = NULL;
  state->allocator_installed = 0;
}

static void *fault_allocator(void *argument, void *pointer,
                             size_t old_size, size_t new_size) {
  thread_fault_domain *state = argument;
  int match = 0;
  if (state->allocator_budget && new_size > 0) {
    if (state->fault_stack)
      match = pointer == state->fault_stack && new_size > old_size;
    else if (state->userdata_entry || state->listener_return_failures ||
             state->map_admission_failures) {
      if (!state->userdata_size && pointer == NULL)
        state->userdata_size = new_size;
      match = pointer == NULL && new_size == state->userdata_size;
    }
  }
  if (match) {
    state->allocator_hits++;
    state->allocation_bytes = new_size > INT_MAX ? INT_MAX : (int)new_size;
    state->allocator_budget--;
    if (!state->allocator_budget) {
      restore_allocator(state);
      state->fault_stack = NULL;
      state->fault_thread = NULL;
    }
    return NULL;
  }
  return state->allocator(state->allocator_data, pointer, old_size, new_size);
}

static void install_allocator(thread_fault_domain *state, lua_State *thread,
                              int budget) {
  state->allocator = lua_getallocf(thread, &state->allocator_data);
  state->allocator_thread = thread;
  state->allocator_budget = budget;
  state->allocator_installed = 1;
  lua_setallocf(thread, fault_allocator, state);
}

int __wrap_luaD_growstack(lua_State *thread, int needed, int raise_error) {
  thread_fault_domain *state = domain;
  if (state && on_host(state) && state->fault_thread == thread &&
      state->allocator_budget == 0) {
    /* Only a naturally requested growth is eligible. Lua's stack reallocator
     * disables emergency collection while stack references are offsets, so
     * this one real allocator failure becomes its ordinary memory error. */
    state->stack_growth++;
    state->fault_stack = thread->stack.p;
    install_allocator(state, thread, 1);
  }
  return __real_luaD_growstack(thread, needed, raise_error);
}

void __wrap_luaH_set(lua_State *thread, Table *map, const TValue *key, TValue *value) {
  thread_fault_domain *state = domain;
  int host = state && on_host(state) && G(thread) == state->host_global;
  int thread_key = host && ttisfulluserdata(key) && ttisfalse(value);
  if (thread_key && state->map_probe)
    state->map_thread_metatable = uvalue(key)->metatable;
  if (!thread_key || !state->map_admission_armed ||
      uvalue(key)->metatable != state->map_thread_metatable) {
    __real_luaH_set(thread, map, key, value);
    return;
  }
  state->map_admission_armed = 0;
  state->map_admission_failures++;
  uv_mutex_lock(&state->mutex);
  /* Correct pre-start admission never consumes this selected create. Later
   * successful slot/FIFO witnesses are ordinary unselected Group children. */
  if (!state->created) state->capture_next = 0;
  uv_mutex_unlock(&state->mutex);
  state->userdata_size = 0;
  install_allocator(state, thread, 2);
  __real_luaH_set(thread, map, key, value);
  restore_allocator(state);
  state->allocator_budget = 0;
}

CClosure *__wrap_luaF_newCclosure(lua_State *thread, int upvalues) {
  thread_fault_domain *state = domain;
  CClosure *result;
  void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
  int selected = state && on_host(state) && G(thread) == state->host_global;
  if (selected && state->listener_probe)
    state->listener_return_caller = caller;
  if (!selected || !state->listener_return_armed ||
      caller != state->listener_return_caller)
    return __real_luaF_newCclosure(thread, upvalues);
  state->listener_return_armed = 0;
  state->listener_return_failures++;
  state->userdata_size = 0;
  install_allocator(state, thread, 2);
  result = __real_luaF_newCclosure(thread, upvalues);
  restore_allocator(state);
  state->allocator_budget = 0;
  return result;
}

Udata *__wrap_luaS_newudata(lua_State *thread, size_t size, unsigned short values) {
  thread_fault_domain *state = domain;
  Udata *result;
  void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
  int host = state && on_host(state) && G(thread) == state->host_global;
  int registration = host && state->listener_registration_armed &&
    caller == state->listener_registration_caller;
  if (host && state->listener_probe)
    state->listener_registration_caller = caller;
  if (!host || (!state->userdata_armed && !registration))
    return __real_luaS_newudata(thread, size, values);
  state->userdata_armed = 0;
  if (registration) {
    state->listener_registration_armed = 0;
    state->listener_registration_failures++;
  }
  state->userdata_entry++;
  state->userdata_size = 0;
  /* Normal first try plus Lua's emergency-collection retry. This is a scoped
   * fixture allocator, not process malloc replacement or a guessed size. */
  install_allocator(state, thread, 2);
  result = __real_luaS_newudata(thread, size, values);
  restore_allocator(state);
  state->allocator_budget = 0;
  return result;
}


int titan_thread_fault_init(lua_State *thread) {
  thread_fault_domain *state;
  int initialized = 0;
  if (domain) return 0;
  state = calloc(1, sizeof(*state));
  if (!state) return 0;
  if (uv_mutex_init(&state->mutex)) { free(state); return 0; }
  if (uv_sem_init(&state->events, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->started, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->cleanup_entered, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->cleanup_release, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->exit_release, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->native_release, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->entry_release, 0)) goto fail;
  initialized++;
  if (uv_sem_init(&state->entry_completed, 0)) goto fail;
  initialized++;
  state->host = uv_thread_self();
  state->host_global = G(thread);
  if (__real_uv_thread_create(&state->witness, witness_main, state)) goto fail;
  state->witness_started = 1;
  domain = state;
  return 1;
fail:
  if (initialized >= 8) uv_sem_destroy(&state->entry_completed);
  if (initialized >= 7) uv_sem_destroy(&state->entry_release);
  if (initialized >= 6) uv_sem_destroy(&state->native_release);
  if (initialized >= 5) uv_sem_destroy(&state->exit_release);
  if (initialized >= 4) uv_sem_destroy(&state->cleanup_release);
  if (initialized >= 3) uv_sem_destroy(&state->cleanup_entered);
  if (initialized >= 2) uv_sem_destroy(&state->started);
  if (initialized >= 1) uv_sem_destroy(&state->events);
  uv_mutex_destroy(&state->mutex);
  free(state);
  return 0;
}

void titan_thread_fault_arm_worker(void) {
  uv_mutex_lock(&domain->mutex);
  domain->capture_next = 1;
  uv_mutex_unlock(&domain->mutex);
}
void titan_thread_fault_arm_worker_entry_gate(void) {
  uv_mutex_lock(&domain->mutex);
  domain->gate_entry = 1;
  uv_mutex_unlock(&domain->mutex);
}
void titan_thread_fault_arm_finished_before_create_return(void) {
  uv_mutex_lock(&domain->mutex);
  domain->finish_before_create_return = 1;
  uv_mutex_unlock(&domain->mutex);
}
void titan_thread_fault_release_worker_entry(void) {
  thread_fault_domain *state = domain;
  int release;
  uv_mutex_lock(&state->mutex);
  release = !state->entry_released;
  state->entry_released = 1;
  uv_mutex_unlock(&state->mutex);
  if (release) uv_sem_post(&state->entry_release);
}
void titan_thread_fault_wait_started(void) { uv_sem_wait(&domain->started); }
void titan_thread_fault_wait_cleanup(void) { uv_sem_wait(&domain->cleanup_entered); }
void titan_thread_fault_child_started(void) {
  uv_mutex_lock(&domain->mutex);
  domain->child_started++;
  uv_mutex_unlock(&domain->mutex);
  uv_sem_post(&domain->started);
}
void titan_thread_fault_child_cleanup(void) {
  thread_fault_domain *state = domain;
  uv_mutex_lock(&state->mutex);
  state->child_cleanup++;
  uv_mutex_unlock(&state->mutex);
  uv_sem_post(&state->cleanup_entered);
  signal_event(state);
  uv_sem_wait(&state->cleanup_release);
}
void titan_thread_fault_release_cleanup(void) {
  thread_fault_domain *state = domain;
  int release;
  uv_mutex_lock(&state->mutex);
  release = !state->cleanup_released;
  state->cleanup_released = 1;
  uv_mutex_unlock(&state->mutex);
  if (release) uv_sem_post(&state->cleanup_release);
}
void titan_thread_fault_terminal(void) {
  thread_fault_domain *state = domain;
  titan_thread_fault_disarm();
  uv_mutex_lock(&state->mutex);
  state->terminals++;
  if (state->real_joins != 1) state->early_terminals++;
  uv_mutex_unlock(&state->mutex);
  signal_event(state);
}
void titan_thread_fault_fail_join_once(void) { domain->fail_join = 1; }
int titan_thread_fault_join_error(void) { return UV_EAGAIN; }
void titan_thread_fault_arm_userdata_oom(void) { domain->userdata_armed = 1; }
void titan_thread_fault_arm_stack_oom(lua_State *thread) {
  domain->fault_thread = thread;
}
void titan_thread_fault_begin_packet_probe(void) {
  domain->packet_probe_pointer = NULL;
  domain->packet_probe_caller = NULL;
  domain->packet_probe = 1;
}
int titan_thread_fault_finish_packet_probe(const void *message) {
  thread_fault_domain *state = domain;
  state->packet_probe = 0;
  if (!message || message != state->packet_probe_pointer ||
      !state->packet_probe_caller) return 0;
  state->packet_copy_caller = state->packet_probe_caller;
  return 1;
}
void titan_thread_fault_arm_packet_copy_oom(void) {
  domain->packet_copy_failures = 0;
  domain->allocation_bytes = 0;
  domain->packet_copy_armed = domain->packet_copy_caller != NULL;
}
void titan_thread_fault_wide_body(void) { domain->wide_body++; }
void titan_thread_fault_forward_hook(void) { domain->forward_hook++; }
void *titan_thread_fault_context(void) { return domain; }
void titan_thread_fault_set_wake_functions(void (*retain)(void *),
                                         int (*notify)(void *),
                                         void (*release)(void *)) {
  domain->wake_retain = retain;
  domain->wake_notify = notify;
  domain->wake_release = release;
}
static void native_entry(void *argument) {
  thread_fault_domain *state = argument;
  void *target;
  titan_thread_fault_child_started();
  uv_sem_wait(&state->native_release);
  uv_mutex_lock(&state->mutex);
  state->native_finished = 1;
  target = state->wake_target;
  state->wake_target = NULL;
  if (target) state->wake_notify(target);
  uv_mutex_unlock(&state->mutex);
  if (target) state->wake_release(target);
}
int titan_thread_fault_start_native(void) {
  titan_thread_fault_arm_worker();
  return __wrap_uv_thread_create(&domain->direct_worker, native_entry, domain);
}
void titan_thread_fault_release_native(void) {
  thread_fault_domain *state = domain;
  int release;
  uv_mutex_lock(&state->mutex);
  release = !state->native_released;
  state->native_released = 1;
  uv_mutex_unlock(&state->mutex);
  if (release) uv_sem_post(&state->native_release);
}
int titan_thread_fault_register(void *context, void *target) {
  thread_fault_domain *state = context;
  int pending;
  uv_mutex_lock(&state->mutex);
  pending = !state->native_finished;
  if (pending) {
    state->wake_retain(target);
    state->wake_target = target;
  }
  uv_mutex_unlock(&state->mutex);
  return pending;
}
void titan_thread_fault_unregister(void *context) {
  thread_fault_domain *state = context;
  void *target;
  uv_mutex_lock(&state->mutex);
  target = state->wake_target;
  state->wake_target = NULL;
  uv_mutex_unlock(&state->mutex);
  if (target) state->wake_release(target);
}
int titan_thread_fault_retire(void *context) {
  thread_fault_domain *state = context;
  int finished;
  int joined;
  uv_mutex_lock(&state->mutex);
  finished = state->native_finished;
  joined = state->real_joins != 0;
  uv_mutex_unlock(&state->mutex);
  if (joined) return 0;
  if (!finished) return 1;
  return __wrap_uv_thread_join(&state->direct_worker);
}
void titan_thread_fault_begin_listener_probe(void) {
  domain->listener_return_caller = NULL;
  domain->listener_registration_caller = NULL;
  domain->listener_probe = 1;
}
int titan_thread_fault_finish_listener_probe(void) {
  domain->listener_probe = 0;
  return domain->listener_return_caller != NULL &&
    domain->listener_registration_caller != NULL;
}
void titan_thread_fault_arm_listener_return_oom(void) {
  domain->listener_return_armed = domain->listener_return_caller != NULL;
}
void titan_thread_fault_arm_listener_registration_oom(void) {
  domain->listener_registration_armed = domain->listener_registration_caller != NULL;
}

void titan_thread_fault_begin_map_probe(void) {
  domain->map_thread_metatable = NULL;
  domain->map_probe = 1;
}
int titan_thread_fault_finish_map_probe(void) {
  domain->map_probe = 0;
  return domain->map_thread_metatable != NULL;
}
void titan_thread_fault_arm_map_admission_oom(void) {
  domain->map_admission_armed = domain->map_thread_metatable != NULL;
}
void titan_thread_fault_fail_create_once(void) { domain->fail_create = 1; }
int titan_thread_fault_create_error(void) { return UV_EAGAIN; }

void titan_thread_fault_disarm(void) {
  thread_fault_domain *state = domain;
  if (!state) return;
  restore_allocator(state);
  state->allocator_budget = 0;
  state->userdata_armed = 0;
  state->fault_thread = NULL;
  state->fault_stack = NULL;
  state->packet_probe = 0;
  state->packet_copy_armed = 0;
  state->listener_probe = 0;
  state->listener_return_armed = 0;
  state->listener_registration_armed = 0;
  state->map_probe = 0;
  state->map_admission_armed = 0;
  state->fail_create = 0;
}
int titan_thread_fault_counter(int counter) {
  thread_fault_domain *state = domain;
  int value = -1;
  uv_mutex_lock(&state->mutex);
  switch (counter) {
  case TITAN_THREAD_FAULT_CREATED: value = state->created; break;
  case TITAN_THREAD_FAULT_CHILD_CLEANUP: value = state->child_cleanup; break;
  case TITAN_THREAD_FAULT_ENTRY_RETURNED: value = state->entry_returned; break;
  case TITAN_THREAD_FAULT_TAIL_RELEASED: value = state->tail_released; break;
  case TITAN_THREAD_FAULT_JOIN_ATTEMPTS: value = state->join_attempts; break;
  case TITAN_THREAD_FAULT_JOIN_FAILURES: value = state->join_failures; break;
  case TITAN_THREAD_FAULT_REAL_JOINS: value = state->real_joins; break;
  case TITAN_THREAD_FAULT_TERMINALS: value = state->terminals; break;
  case TITAN_THREAD_FAULT_EARLY_TERMINALS: value = state->early_terminals; break;
  case TITAN_THREAD_FAULT_CHANGED_TOKEN: value = state->changed_token; break;
  case TITAN_THREAD_FAULT_STACK_GROWTH: value = state->stack_growth; break;
  case TITAN_THREAD_FAULT_ALLOCATOR_HITS: value = state->allocator_hits; break;
  case TITAN_THREAD_FAULT_USERDATA_ENTRY: value = state->userdata_entry; break;
  case TITAN_THREAD_FAULT_ALLOCATION_BYTES: value = state->allocation_bytes; break;
  case TITAN_THREAD_FAULT_WIDE_BODY: value = state->wide_body; break;
  case TITAN_THREAD_FAULT_FORWARD_HOOK: value = state->forward_hook; break;
  case TITAN_THREAD_FAULT_PACKET_COPY_FAILURES: value = state->packet_copy_failures; break;
  case TITAN_THREAD_FAULT_CHILD_STARTED: value = state->child_started; break;
  case TITAN_THREAD_FAULT_LISTENER_RETURN_FAILURES:
    value = state->listener_return_failures; break;
  case TITAN_THREAD_FAULT_LISTENER_REGISTRATION_FAILURES:
    value = state->listener_registration_failures; break;
  case TITAN_THREAD_FAULT_MAP_ADMISSION_FAILURES:
    value = state->map_admission_failures; break;
  case TITAN_THREAD_FAULT_CREATE_FAILURES: value = state->create_failures; break;
  }
  uv_mutex_unlock(&state->mutex);
  return value;
}
const char *titan_thread_fault_memory_error(lua_State *thread) {
  return getstr(G(thread)->memerrmsg);
}
void titan_thread_fault_report(void) {
  thread_fault_domain *state = domain;
  if (!state) return;
  uv_mutex_lock(&state->mutex);
  printf("THREAD_RETIREMENT_NATIVE created=%d cleanup=%d entry_returned=%d "
         "tail_released=%d join_attempts=%d join_failures=%d real_joins=%d "
         "terminals=%d early_terminals=%d changed_token=%d growth=%d "
         "allocator_hits=%d userdata_entry=%d bytes=%d wide_body=%d hook=%d "
         "packet_copy_failures=%d child_started=%d listener_return_failures=%d "
         "listener_registration_failures=%d map_admission_failures=%d create_failures=%d\n",
         state->created, state->child_cleanup, state->entry_returned,
         state->tail_released, state->join_attempts, state->join_failures,
         state->real_joins, state->terminals, state->early_terminals,
         state->changed_token, state->stack_growth, state->allocator_hits,
         state->userdata_entry, state->allocation_bytes, state->wide_body,
         state->forward_hook, state->packet_copy_failures, state->child_started,
         state->listener_return_failures, state->listener_registration_failures,
         state->map_admission_failures, state->create_failures);
  fflush(stdout);
  uv_mutex_unlock(&state->mutex);
}

void titan_thread_fault_shutdown(void) {
  thread_fault_domain *state = domain;
  if (!state) return;
  titan_thread_fault_disarm();
  titan_thread_fault_release_native();
  titan_thread_fault_release_cleanup();
  titan_thread_fault_release_worker_entry();
  uv_mutex_lock(&state->mutex);
  state->aborting = 1;
  if (!state->created) state->entry_returned = 1;
  uv_mutex_unlock(&state->mutex);
  signal_event(state);
  if (state->witness_started) __real_uv_thread_join(&state->witness);
  /* A failing old provider may detach or publish terminal without joining.
   * Never fake the missing production join during cleanup. Keep its C domain
   * process-owned rather than freeing storage a still-exiting worker borrows.
   * Passing cases prove the real join, then reclaim every fixture resource. */
  if (state->created && !state->real_joins) return;
  titan_thread_fault_unregister(state);
  uv_sem_destroy(&state->entry_completed);
  uv_sem_destroy(&state->entry_release);
  uv_sem_destroy(&state->native_release);
  uv_sem_destroy(&state->exit_release);
  uv_sem_destroy(&state->cleanup_release);
  uv_sem_destroy(&state->cleanup_entered);
  uv_sem_destroy(&state->started);
  uv_sem_destroy(&state->events);
  uv_mutex_destroy(&state->mutex);
  domain = NULL;
  free(state);
}
#else
int titan_thread_retirement_fault_unsupported_host;
#endif
