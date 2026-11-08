#ifndef TITAN_ASYNC_BROWSER_TESTS_CHILD_H
#define TITAN_ASYNC_BROWSER_TESTS_CHILD_H
#include <titan/browser.h>

/* Test-only C-created child states that load async.browser_child
 * (spec/fixtures/browser_scheduler/scheduler_child.c). */
TValue scheduler_new_child(lua_State *L);
void scheduler_child_check(lua_State *L, TValue owner);
void scheduler_close_child(lua_State *L, TValue owner);
#endif
