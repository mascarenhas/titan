#include "sqlite3_worker_fixture.h"

#include <errno.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#include <sys/time.h>
#endif

/*
 * A normal SQLite auto-extension supplies deterministic worker boundaries.
 * This object links only into a standalone consumer of the canonical provider:
 * its static SQLite on Unix, the same controlled SQLite DLL on Windows. It
 * neither interposes symbols nor changes provider source, and every SQLite
 * callback below is ordinary C with no Titan state.
 */
#ifdef _WIN32
static SRWLOCK fixture_mutex = SRWLOCK_INIT;
static CONDITION_VARIABLE fixture_condition = CONDITION_VARIABLE_INIT;

static void fixture_lock(void) {
  AcquireSRWLockExclusive(&fixture_mutex);
}

static void fixture_unlock(void) {
  ReleaseSRWLockExclusive(&fixture_mutex);
}

static void fixture_wake_all(void) {
  WakeAllConditionVariable(&fixture_condition);
}
#else
static pthread_mutex_t fixture_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fixture_condition = PTHREAD_COND_INITIALIZER;

static void fixture_lock(void) {
  (void)pthread_mutex_lock(&fixture_mutex);
}

static void fixture_unlock(void) {
  (void)pthread_mutex_unlock(&fixture_mutex);
}

static void fixture_wake_all(void) {
  (void)pthread_cond_broadcast(&fixture_condition);
}
#endif
static int armed_point;
static int gate_ready;
static int gate_released;
static int gate_completed;
static int gate_timed_out;
static int live_connections;
static int closed_connections;
static int live_blobs;
static int released_blobs;

/* Only the owning Lua thread accesses this supported allocator callback.
 * Workers keep using native malloc. Small continuation/cleanup allocations
 * remain available while large result decoding fails, including the
 * allocator's retry after emergency GC. */
static lua_Alloc previous_allocator;
static void *previous_allocator_data;
static size_t allocation_threshold;
static int allocator_active;
static int failed_allocations;

static void *limited_allocator(void *unused, void *pointer, size_t old_size,
                                size_t new_size) {
  (void)unused;
  if (new_size >= allocation_threshold && new_size > old_size) {
    failed_allocations++;
    return NULL;
  }
  return previous_allocator(previous_allocator_data, pointer, old_size, new_size);
}

int titan_sqlite_fixture_limit_allocations(lua_State *state, size_t threshold) {
  if (allocator_active || threshold == 0)
    return -1;
  previous_allocator = lua_getallocf(state, &previous_allocator_data);
  allocation_threshold = threshold;
  failed_allocations = 0;
  allocator_active = 1;
  lua_setallocf(state, limited_allocator, NULL);
  return 0;
}

void titan_sqlite_fixture_restore_allocator(lua_State *state) {
  if (!allocator_active)
    return;
  lua_setallocf(state, previous_allocator, previous_allocator_data);
  allocator_active = 0;
}

int titan_sqlite_fixture_failed_allocations(void) {
  return failed_allocations;
}

static void gate(int point) {
#ifdef _WIN32
  ULONGLONG deadline;
#else
  struct timeval now;
  struct timespec deadline;
#endif
  int status = 0;

  fixture_lock();
  if (armed_point != point) {
    fixture_unlock();
    return;
  }
  armed_point = 0;
  gate_ready = 1;
#ifdef _WIN32
  deadline = GetTickCount64() + 15000;
  while (!gate_released && status == 0) {
    ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      status = ETIMEDOUT;
      break;
    }
    if (!SleepConditionVariableSRW(&fixture_condition, &fixture_mutex,
                                    (DWORD)(deadline - now), 0)) {
      DWORD error = GetLastError();
      status = error == ERROR_TIMEOUT ? ETIMEDOUT : (int)error;
    }
  }
#else
  (void)gettimeofday(&now, NULL);
  deadline.tv_sec = now.tv_sec + 15;
  deadline.tv_nsec = now.tv_usec * 1000;
  while (!gate_released && status == 0)
    status = pthread_cond_timedwait(&fixture_condition, &fixture_mutex,
                                    &deadline);
#endif
  if (!gate_released)
    gate_timed_out = status == 0 ? ETIMEDOUT : status;
  gate_completed = 1;
  fixture_unlock();
}

int titan_sqlite_fixture_arm(int point) {
  int status = 0;
  fixture_lock();
  if (point < TITAN_SQLITE_GATE_OPEN || point > TITAN_SQLITE_GATE_RESET ||
      armed_point != 0 || (gate_ready && !gate_completed)) {
    status = -1;
  } else {
    armed_point = point;
    gate_ready = 0;
    gate_released = 0;
    gate_completed = 0;
    gate_timed_out = 0;
  }
  fixture_unlock();
  return status;
}

static int read_statistic(const int *statistic) {
  int result;
  fixture_lock();
  result = *statistic;
  fixture_unlock();
  return result;
}

int titan_sqlite_fixture_ready(void) {
  return read_statistic(&gate_ready);
}

void titan_sqlite_fixture_release(void) {
  fixture_lock();
  gate_released = 1;
  fixture_wake_all();
  fixture_unlock();
}

int titan_sqlite_fixture_completed(void) {
  return read_statistic(&gate_completed);
}

int titan_sqlite_fixture_timed_out(void) {
  return read_statistic(&gate_timed_out);
}

int titan_sqlite_fixture_live_connections(void) {
  return read_statistic(&live_connections);
}

int titan_sqlite_fixture_closed_connections(void) {
  return read_statistic(&closed_connections);
}

int titan_sqlite_fixture_live_blobs(void) {
  return read_statistic(&live_blobs);
}

int titan_sqlite_fixture_released_blobs(void) {
  return read_statistic(&released_blobs);
}

static int authorize(void *unused, int action, const char *first,
                      const char *second, const char *database,
                      const char *source) {
  (void)unused;
  (void)action;
  (void)first;
  (void)second;
  (void)database;
  (void)source;
  gate(TITAN_SQLITE_GATE_PREPARE);
  return SQLITE_OK;
}

static void connection_destroy(void *owner) {
  gate(TITAN_SQLITE_GATE_CLOSE);
  fixture_lock();
  live_connections--;
  closed_connections++;
  fixture_unlock();
  free(owner);
}

static void connection_value(sqlite3_context *context, int argc,
                             sqlite3_value **argv) {
  (void)argc;
  (void)argv;
  sqlite3_result_int(context, 1);
}

static void blocking_value(sqlite3_context *context, int argc,
                           sqlite3_value **argv) {
  (void)argc;
  (void)argv;
  gate(TITAN_SQLITE_GATE_STEP);
  sqlite3_result_int(context, 47);
}

static void blob_destroy(void *bytes) {
  gate(TITAN_SQLITE_GATE_RESET);
  fixture_lock();
  live_blobs--;
  released_blobs++;
  fixture_unlock();
  free(bytes);
}

static void owned_value(sqlite3_context *context, int argc,
                        sqlite3_value **argv) {
  void *bytes;
  (void)argc;
  (void)argv;
  bytes = malloc(8);
  if (bytes == NULL) {
    sqlite3_result_error_nomem(context);
    return;
  }
  memcpy(bytes, "raw\0data", 8);
  fixture_lock();
  live_blobs++;
  fixture_unlock();
  sqlite3_result_blob(context, bytes, 8, blob_destroy);
}

static void statement_count(sqlite3_context *context, int argc,
                            sqlite3_value **argv) {
  sqlite3 *database = sqlite3_context_db_handle(context);
  sqlite3_stmt *statement = NULL;
  int count = 0;
  (void)argc;
  (void)argv;
  while ((statement = sqlite3_next_stmt(database, statement)) != NULL)
    count++;
  sqlite3_result_int(context, count);
}

static int extension_init(sqlite3 *database, char **error,
                          const sqlite3_api_routines *api) {
  void *owner;
  int status;
  (void)error;
  (void)api;
  owner = malloc(1);
  if (owner == NULL)
    return SQLITE_NOMEM;
  fixture_lock();
  live_connections++;
  fixture_unlock();
  /* SQLite calls this destructor even when create_function_v2 fails. */
  status = sqlite3_create_function_v2(database, "titan_test_connection", 0,
      SQLITE_UTF8, owner, connection_value, NULL, NULL, connection_destroy);
  if (status != SQLITE_OK)
    return status;
  status = sqlite3_create_function_v2(database, "titan_test_gate", 0,
      SQLITE_UTF8, NULL, blocking_value, NULL, NULL, NULL);
  if (status != SQLITE_OK)
    return status;
  status = sqlite3_create_function_v2(database, "titan_test_owned", 0,
      SQLITE_UTF8, NULL, owned_value, NULL, NULL, NULL);
  if (status != SQLITE_OK)
    return status;
  status = sqlite3_create_function_v2(database, "titan_test_statement_count", 0,
      SQLITE_UTF8, NULL, statement_count, NULL, NULL, NULL);
  if (status != SQLITE_OK)
    return status;
  status = sqlite3_set_authorizer(database, authorize, NULL);
  if (status != SQLITE_OK)
    return status;
  gate(TITAN_SQLITE_GATE_OPEN);
  return SQLITE_OK;
}

int titan_sqlite_fixture_install(void) {
  return sqlite3_auto_extension((void (*)(void))extension_init);
}
