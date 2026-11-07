#ifndef TITAN_BROWSER_TEST_NATIVE_H
#define TITAN_BROWSER_TEST_NATIVE_H
#include <stdio.h>
#include <titan/browser.h>
void gate_test_publish(void);
TValue titan_bridge_test_new_state(lua_State *L, int index);
void titan_bridge_test_close_state(lua_State *L, TValue owner);
void *titan_bridge_test_detach_state(lua_State *L, TValue owner);
void titan_bridge_test_close_detached(void *state);
void titan_bridge_test_check_state(lua_State *L, TValue owner);
void titan_bridge_test_write(lua_State *L, TValue success, TValue failure,
    const unsigned char *bytes, uint32_t length);
void titan_bridge_test_read(lua_State *L, TValue success, TValue failure, uint32_t capacity);
void titan_bridge_test_arm_identity_gc(lua_State *L, int after);
void titan_bridge_test_arm_admission_failure(lua_State *L);
int titan_bridge_test_finish_admission_failure(lua_State *L);
void titan_bridge_test_prepare_response_failure(lua_State *L);
int titan_bridge_test_finish_response_failure(lua_State *L);
#endif
