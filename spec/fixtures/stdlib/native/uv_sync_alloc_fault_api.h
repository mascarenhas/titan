#ifndef TITAN_TEST_UV_SYNC_ALLOC_FAULT_API_H
#define TITAN_TEST_UV_SYNC_ALLOC_FAULT_API_H

#include "lua.h"

int titan_uv_mutex_fault_install(lua_State *state);
void titan_uv_mutex_fault_restore(lua_State *state);
void titan_uv_mutex_fault_arm(int mode);
void titan_uv_mutex_fault_disarm(void);
int titan_uv_mutex_fault_allocations(void);
int titan_uv_mutex_fault_initializations(void);
int titan_uv_mutex_fault_failures(void);
int titan_uv_mutex_fault_frees(void);
void titan_uv_thread_fault_arm(int mode);
void titan_uv_thread_fault_disarm(void);
int titan_uv_thread_fault_failures(void);
int titan_uv_thread_fault_frees(void);
int titan_uv_thread_fault_allocations(void);
int titan_uv_thread_fault_creations(void);
void titan_uv_thread_fault_worker(void *argument);

#endif
