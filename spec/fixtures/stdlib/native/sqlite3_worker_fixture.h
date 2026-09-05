#ifndef TITAN_TEST_SQLITE3_WORKER_FIXTURE_H
#define TITAN_TEST_SQLITE3_WORKER_FIXTURE_H

#include <lua.h>
#include <stddef.h>

#define TITAN_SQLITE_GATE_OPEN 1
#define TITAN_SQLITE_GATE_PREPARE 2
#define TITAN_SQLITE_GATE_STEP 3
#define TITAN_SQLITE_GATE_CLOSE 4
#define TITAN_SQLITE_GATE_RESET 5

int titan_sqlite_fixture_install(void);
int titan_sqlite_fixture_arm(int point);
int titan_sqlite_fixture_ready(void);
void titan_sqlite_fixture_release(void);
int titan_sqlite_fixture_completed(void);
int titan_sqlite_fixture_timed_out(void);
int titan_sqlite_fixture_live_connections(void);
int titan_sqlite_fixture_closed_connections(void);
int titan_sqlite_fixture_live_blobs(void);
int titan_sqlite_fixture_released_blobs(void);
int titan_sqlite_fixture_limit_allocations(lua_State *state, size_t threshold);
void titan_sqlite_fixture_restore_allocator(lua_State *state);
int titan_sqlite_fixture_failed_allocations(void);

#endif
