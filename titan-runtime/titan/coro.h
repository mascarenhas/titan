#ifndef TITAN_CORO_H
#define TITAN_CORO_H

#include "ffi.h"

/*
** Private, unsafe FFI boundary for the standard coro.titan module.
** titan_coro_ref values are borrowed from their owning coroutine handle or
** the currently running coroutine; Titan code must not store them or call
** these transfer primitives outside the wrapper protocol in coro.titan.
*/
typedef struct mco_coro mco_coro;
typedef mco_coro *titan_coro_ref;

enum {
  TITAN_CORO_SUCCESS = 0,
  TITAN_CORO_STATUS_DEAD = 0,
  TITAN_CORO_STATUS_NORMAL = 1,
  TITAN_CORO_STATUS_RUNNING = 2,
  TITAN_CORO_STATUS_SUSPENDED = 3,
  TITAN_CORO_STATUS_STACKED = 4
};

TValue titan_coro_create(lua_State *L, TValue func);
titan_coro_ref titan_coro_handle(TValue handle);
titan_coro_ref titan_coro_running(void);
titan_coro_ref titan_coro_transfer_source(titan_coro_ref co);
int titan_coro_push_value(titan_coro_ref co, TValue payload);
int titan_coro_push_int(titan_coro_ref co, int value);
TValue titan_coro_pop_value(lua_State *L, titan_coro_ref co);
int titan_coro_pop_int(lua_State *L, titan_coro_ref co);
void titan_coro_discard_transfer(titan_coro_ref co);
int titan_coro_resume(titan_coro_ref co, TValue tag);
int titan_coro_yield(titan_coro_ref co, TValue tag);
int titan_coro_is_yieldable(titan_coro_ref co, TValue tag);
int titan_coro_status(titan_coro_ref co);
void titan_coro_clear_dead(lua_State *L, titan_coro_ref source);
void titan_coro_raise(lua_State *L, titan_coro_ref source, TValue payload);
char *titan_coro_result_name(int result);

#endif
