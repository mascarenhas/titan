#undef NDEBUG
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "titan.h"
#include "minicoro.h"

enum { RAISE, UNWIND, RAISE_THEN_SUSPEND_IN_CLOSE };
static mco_runtime runtime;
static lua_State *thread;
static TValue tag;
static int scenario;
static int closed_with_error;
static int closed_without_error;
static int suspended_in_close;

/* In scenario 3, the first real-error close suspends and an abandonment
 * resumes the coroutine to continue unwinding from its re-armed floor. */
static int close_method(lua_State *L) {
  if (lua_isnoneornil(L, 2)) closed_without_error++;
  else closed_with_error++;
  if (scenario == RAISE_THEN_SUSPEND_IN_CLOSE && !suspended_in_close) {
    suspended_in_close = 1;
    assert(mco_yield(runtime.current_co, &tag) == MCO_SUCCESS);
    titan_unwind(L);
  }
  return 0;
}
static void push_to_be_closed(lua_State *L) {
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, close_method);
  lua_setfield(L, -2, "__close");
  lua_setmetatable(L, -2);
  lua_toclose(L, -1);
}
static void entry(lua_State *L, Udata *module, CClosure *closure, TValue func,
                  struct mco_coro *co) {
  (void)module; (void)closure; (void)func; (void)co;
  push_to_be_closed(L);
  push_to_be_closed(L);
  if (scenario == UNWIND) titan_unwind(L);
  lua_pushliteral(L, "escaped entry error");
  lua_error(L);
}
static void trampoline(mco_coro *co) {
  TValue func;
  setnilvalue(&func);
  titan_coroutine_enter(thread, NULL, func, co, entry);
}
static void run(lua_State *L, int which, int expected_ok, int with_error,
                int without_error) {
  mco_desc desc = mco_desc_init(trampoline, 256 * 1024);
  mco_coro *co = NULL;
  int ok = -1;
  TValue payload;
  int top = lua_gettop(L);
  scenario = which;
  closed_with_error = closed_without_error = suspended_in_close = 0;
  thread = lua_newthread(L);
  lua_newuserdatauv(L, sizeof(void *), 6);
  desc.runtime = &runtime;
  desc.user_data = uvalue(s2v(L->top.p - 1));
  assert(mco_create(&co, &desc) == MCO_SUCCESS);
  assert(mco_resume(co, &tag) == MCO_SUCCESS);
  if (which == RAISE_THEN_SUSPEND_IN_CLOSE) {
    assert(suspended_in_close && mco_status(co) == MCO_SUSPENDED);
    assert(mco_resume(co, &tag) == MCO_SUCCESS);
  }
  assert(mco_status(co) == MCO_DEAD);
  assert(mco_pop(co, &ok, sizeof ok) == MCO_SUCCESS);
  assert(mco_pop(co, &payload, sizeof payload) == MCO_SUCCESS);
  assert(ok == expected_ok);
  if (expected_ok == 0) {
    assert(ttisstring(&payload));
    assert(strstr(getstr(tsvalue(&payload)), "escaped entry error") != NULL);
  } else {
    assert(ttisnil(&payload));
  }
  assert(closed_with_error == with_error);
  assert(closed_without_error == without_error);
  assert(thread->errorJmp == NULL);
  assert(mco_destroy(co) == MCO_SUCCESS);
  lua_settop(L, top);
}
int main(void) {
  lua_State *L = luaL_newstate();
  assert(L != NULL);
  setivalue(&tag, 7);
  run(L, RAISE, 0, 2, 0);
  run(L, UNWIND, 2, 0, 2);
  run(L, RAISE_THEN_SUSPEND_IN_CLOSE, 2, 1, 1);
  lua_close(L);
  puts("ok");
  return 0;
}
