#ifndef TITAN_TEST_UV_COVERAGE_THREADS_H
#define TITAN_TEST_UV_COVERAGE_THREADS_H

/* C-only carriers for the public UV entries. No libuv layout or Lua/Titan
 * objects are visible to a worker. The Titan caller retains every pointee and
 * joins all workers before destroying the synchronization owners. */
typedef struct titan_cov_su_rwlock {
  void *lock;
  void (*read_lock)(void *);
  int (*try_read)(void *);
  void (*read_unlock)(void *);
  void (*write_lock)(void *);
  int (*try_write)(void *);
  void (*write_unlock)(void *);
  int mode;
  int read_status;
  int write_status;
  int blocking_value;
} titan_cov_su_rwlock;

static void titan_cov_su_probe_lock(void *argument) {
  titan_cov_su_rwlock *state = (titan_cov_su_rwlock *)argument;
  if (state->mode == 1) {
    state->read_lock(state->lock);
    state->blocking_value += 10;
    state->read_unlock(state->lock);
    state->write_lock(state->lock);
    state->blocking_value += 32;
    state->write_unlock(state->lock);
    return;
  }
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


typedef struct titan_cov_su_sync_matrix {
  void *mutex;
  void *cond;
  void *sem;
  void *barrier;
  void *start;
  void (*mutex_lock)(void *);
  int (*mutex_trylock)(void *);
  void (*mutex_unlock)(void *);
  void (*cond_signal)(void *);
  void (*cond_broadcast)(void *);
  void (*cond_wait)(void *, void *);
  void (*sem_post)(void *);
  void (*sem_wait)(void *);
  int (*sem_trywait)(void *);
  int (*barrier_wait)(void *);
  int arrived;
  int serial_count;
  int zero_count;
  int error_count;
  int all_arrived_before_release;
  int abort_barrier;
  int predicate_phase;
  int cond_wait_released_mutex;
  int spurious_recheck_held;
  int cond_waiters_ready;
  int cond_waiters_done;
  int phase_one_rechecks;
  int trylock_busy_status;
  int trylock_free_status;
  int trywait_empty_status;
  int trywait_ready_status;
  int trywait_after_status;
} titan_cov_su_sync_matrix;

static void titan_cov_su_barrier_participant(void *argument) {
  titan_cov_su_sync_matrix *state = (titan_cov_su_sync_matrix *)argument;
  int rc;
  state->sem_wait(state->start);
  if (state->abort_barrier)
    return;
  state->mutex_lock(state->mutex);
  state->arrived++;
  state->mutex_unlock(state->mutex);
  rc = state->barrier_wait(state->barrier);
  state->mutex_lock(state->mutex);
  if (state->arrived != 3)
    state->all_arrived_before_release = 0;
  if (rc > 0)
    state->serial_count++;
  else if (rc == 0)
    state->zero_count++;
  else
    state->error_count++;
  state->mutex_unlock(state->mutex);
}

static void titan_cov_su_cond_wait_worker(void *argument) {
  titan_cov_su_sync_matrix *state = (titan_cov_su_sync_matrix *)argument;
  state->mutex_lock(state->mutex);
  state->cond_waiters_ready++;
  state->sem_post(state->sem);
  while (state->predicate_phase < 2) {
    state->cond_wait(state->cond, state->mutex);
    if (state->predicate_phase == 1 && state->phase_one_rechecks == 0) {
      state->phase_one_rechecks++;
      state->cond_broadcast(state->cond);
    }
  }
  state->cond_waiters_done++;
  state->mutex_unlock(state->mutex);
  state->sem_post(state->sem);
}

static void titan_cov_su_cond_producer_worker(void *argument) {
  titan_cov_su_sync_matrix *state = (titan_cov_su_sync_matrix *)argument;
  state->sem_wait(state->sem);
  state->sem_wait(state->sem);
  state->trywait_empty_status = state->sem_trywait(state->sem);
  state->sem_post(state->sem);
  state->trywait_ready_status = state->sem_trywait(state->sem);
  state->trywait_after_status = state->sem_trywait(state->sem);
  state->mutex_lock(state->mutex);
  state->cond_wait_released_mutex =
      (state->cond_waiters_ready == 2 && state->cond_waiters_done == 0);
  state->predicate_phase = 1;
  state->cond_signal(state->cond);
  state->mutex_unlock(state->mutex);
  state->mutex_lock(state->mutex);
  while (state->phase_one_rechecks == 0)
    state->cond_wait(state->cond, state->mutex);
  state->spurious_recheck_held =
      (state->phase_one_rechecks > 0 && state->cond_waiters_done == 0);
  state->predicate_phase = 2;
  state->cond_signal(state->cond);
  state->cond_broadcast(state->cond);
  state->mutex_unlock(state->mutex);
}

static void titan_cov_su_try_busy_mutex(void *argument) {
  titan_cov_su_sync_matrix *state = (titan_cov_su_sync_matrix *)argument;
  state->trylock_busy_status = state->mutex_trylock(state->mutex);
  if (state->trylock_busy_status == 0)
    state->mutex_unlock(state->mutex);
}
#endif
