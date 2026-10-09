#ifndef TITAN_TEST_UV_COVERAGE_THREADS_H
#define TITAN_TEST_UV_COVERAGE_THREADS_H

/* C-only carriers for the public UV entries. No libuv layout or Lua/Titan
 * objects are visible to a worker. The Titan caller retains every pointee and
 * joins all workers before destroying the synchronization owners. */
typedef struct titan_cov_su_rwlock {
  void *lock;
  int (*try_read)(void *);
  int (*try_write)(void *);
  void (*read_unlock)(void *);
  void (*write_unlock)(void *);
  int read_status;
  int write_status;
} titan_cov_su_rwlock;

static void titan_cov_su_probe_lock(void *argument) {
  titan_cov_su_rwlock *state = (titan_cov_su_rwlock *)argument;
  state->read_status = state->try_read(state->lock);
  if (state->read_status == 0)
    state->read_unlock(state->lock);
  state->write_status = state->try_write(state->lock);
  if (state->write_status == 0)
    state->write_unlock(state->lock);
}

typedef struct titan_cov_su_condition {
  void *mutex;
  void *condition;
  void *ready;
  void *done;
  void (*lock)(void *);
  void (*unlock)(void *);
  int (*wait)(void *, void *, unsigned long long);
  void (*post)(void *);
  int permits;
  int completed;
  int failed;
} titan_cov_su_condition;

static void titan_cov_su_wait_for_permit(void *argument) {
  titan_cov_su_condition *state = (titan_cov_su_condition *)argument;
  int attempts;
  state->lock(state->mutex);
  state->post(state->ready);
  /* Permit checks handle spurious wakes. Five relative waits bound a broken
   * notification path while leaving ample time for a loaded local VM. */
  for (attempts = 0; state->permits == 0 && attempts < 5; attempts++)
    state->wait(state->condition, state->mutex, 1000000000ULL);
  if (state->permits > 0) {
    state->permits--;
    state->completed++;
  } else {
    state->failed++;
  }
  state->unlock(state->mutex);
  state->post(state->done);
}

typedef struct titan_cov_su_tls {
  void *key;
  void *ready;
  void *release;
  void *(*get)(void *);
  void (*set)(void *, void *);
  void (*post)(void *);
  void (*wait)(void *);
  int (*set_name)(const char *);
  int (*get_cpu)(void);
  int cell;
  int isolated;
  int name_status;
  int cpu;
} titan_cov_su_tls;

static void titan_cov_su_use_tls(void *argument) {
  titan_cov_su_tls *state = (titan_cov_su_tls *)argument;
  state->isolated = state->get(state->key) == 0;
  state->set(state->key, &state->cell);
  state->isolated = state->isolated && state->get(state->key) == &state->cell;
  state->cell = 42;
  state->name_status = state->set_name("titan-cov-su");
  state->cpu = state->get_cpu();
  state->post(state->ready);
  state->wait(state->release);
  state->set(state->key, 0);
  state->isolated = state->isolated && state->get(state->key) == 0;
}

typedef struct titan_cov_su_once {
  void *guard;
  void *start;
  void (*once)(void *, void (*)(void));
  void (*wait)(void *);
} titan_cov_su_once;

static int titan_cov_su_once_calls;
static void titan_cov_su_initialize_once(void) { titan_cov_su_once_calls++; }
static void titan_cov_su_reset_once(void) { titan_cov_su_once_calls = 0; }
static int titan_cov_su_count_once(void) { return titan_cov_su_once_calls; }

static void titan_cov_su_race_once(void *argument) {
  titan_cov_su_once *state = (titan_cov_su_once *)argument;
  state->wait(state->start);
  state->once(state->guard, titan_cov_su_initialize_once);
  state->once(state->guard, titan_cov_su_initialize_once);
}

#endif
