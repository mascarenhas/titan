#ifndef TITAN_CORO_H
#define TITAN_CORO_H

#include "ffi.h"

enum {
  TITAN_CORO_SUCCESS = 0,
  TITAN_CORO_STATUS_SUSPENDED = 0,
  TITAN_CORO_STATUS_RUNNING = 1,
  TITAN_CORO_STATUS_NORMAL = 2,
  TITAN_CORO_STATUS_STACKED = 3,
  TITAN_CORO_STATUS_DEAD = 4
};

TValue titan_coro_create(lua_State *L, TValue func);
int titan_coro_push(lua_State *L, TValue handle, int ok, TValue payload);
int titan_coro_push_current(lua_State *L, int ok, TValue payload);
int titan_coro_resume(lua_State *L, TValue handle, TValue tag);
int titan_coro_yield(lua_State *L, TValue tag);
int titan_coro_pop_ok(lua_State *L, TValue handle);
TValue titan_coro_pop_payload(lua_State *L, TValue handle);
int titan_coro_pop_current_ok(lua_State *L);
TValue titan_coro_pop_current_payload(lua_State *L);
int titan_coro_is_yieldable(lua_State *L, TValue tag);
int titan_coro_status(lua_State *L, TValue handle);
char *titan_coro_result_name(int result);

#endif
