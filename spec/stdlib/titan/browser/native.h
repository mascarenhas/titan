#ifndef TITAN_BROWSER_TEST_NATIVE_H
#define TITAN_BROWSER_TEST_NATIVE_H
#include <stdio.h>
#include <titan/browser.h>
void gate_test_publish(void);
void titan_bridge_test_earlier_cleanup(int index);
TValue titan_bridge_test_new_state(lua_State *L, int index);
void titan_bridge_test_close_state(lua_State *L, TValue owner);
void *titan_bridge_test_detach_state(lua_State *L, TValue owner);
void titan_bridge_test_close_detached(void *state);
void titan_bridge_test_check_state(lua_State *L, TValue owner);
void titan_bridge_test_arm_identity_gc(lua_State *L, int after);
void titan_bridge_test_arm_identity_gc_and_fail(lua_State *L, int after, int arm_oom);
void titan_bridge_test_arm_admission_failure(lua_State *L);
int titan_bridge_test_finish_admission_failure(lua_State *L);
void titan_bridge_test_prepare_response_failure(lua_State *L);
int titan_bridge_test_finish_response_failure(lua_State *L);
void titan_bridge_test_arm_alloc_failure(lua_State *L, int after);
void titan_bridge_test_arm_alloc_failure_count(lua_State *L, int after, int max_failures);
int titan_bridge_test_finish_alloc_failure(lua_State *L);
void titan_bridge_test_fail_malloc(int after);
TValue titan_bridge_test_make_error_object(lua_State *L, int mode);
#endif
