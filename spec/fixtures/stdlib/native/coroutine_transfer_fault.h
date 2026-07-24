#ifndef TITAN_COROUTINE_TRANSFER_FAULT_H
#define TITAN_COROUTINE_TRANSFER_FAULT_H

#include "lua.h"
#include "lobject.h"
#include "titan/ffi.h"

/*
 * Translation-unit-local fault state for the isolated coroutine test image.
 * The production source calls these only after the spec rewrites its private
 * transfer-root helper to use this header.
 */
static int titan_coro_test_checkstack_armed;
static int titan_coro_test_checkstack_failed;
static int titan_coro_test_push_after_failure;
static int titan_coro_test_top_restored;
static int titan_coro_test_saved_top;

static void titan_coro_test_arm_checkstack_failure(void) {
  titan_coro_test_checkstack_armed = 1;
  titan_coro_test_checkstack_failed = 0;
  titan_coro_test_push_after_failure = 0;
  titan_coro_test_top_restored = 0;
  titan_coro_test_saved_top = -1;
}

static int titan_coro_test_lua_checkstack(lua_State *L, int n) {
  if (titan_coro_test_checkstack_armed && n == 2) {
    titan_coro_test_checkstack_armed = 0;
    titan_coro_test_checkstack_failed = 1;
    titan_coro_test_saved_top = lua_gettop(L);
    return 0;
  }
  return lua_checkstack(L, n);
}

static void titan_coro_test_lua_pushtvalue(lua_State *L, TValue value) {
  if (titan_coro_test_checkstack_failed) {
    titan_coro_test_push_after_failure = 1;
    return;
  }
  lua_pushtvalue(L, value);
}

static void titan_coro_test_lua_settop(lua_State *L, int top) {
  lua_settop(L, top);
  if (titan_coro_test_checkstack_failed &&
      top == titan_coro_test_saved_top &&
      lua_gettop(L) == titan_coro_test_saved_top) {
    titan_coro_test_top_restored = 1;
  }
}

static int titan_coro_test_checkstack_failure_ok(void) {
  int ok = titan_coro_test_checkstack_failed &&
           !titan_coro_test_push_after_failure &&
           titan_coro_test_top_restored;
  titan_coro_test_checkstack_failed = 0;
  return ok;
}

#endif
