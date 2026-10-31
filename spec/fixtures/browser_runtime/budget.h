#ifndef TITAN_BROWSER_BUDGET_H
#define TITAN_BROWSER_BUDGET_H
#include <lua.h>
int budget_bridge(lua_State *L);
int budget_load_mixed(lua_State *L);
int budget_load_lua_limit(lua_State *L);
int budget_shadow_bytes(int bytes);
void budget_wait(void);
int budget_check_pad(const unsigned int *pad, unsigned int expected);
int budget_check_tail(const unsigned int *pad, unsigned int expected);
unsigned int budget_last_stack_span(void);
unsigned int budget_last_stack_free(void);
unsigned int budget_heap_size(void);
unsigned int budget_heap_max(void);
void budget_fail_next_create(void);
void budget_reset_failure(void);
int budget_failed_allocator(void);
#endif
