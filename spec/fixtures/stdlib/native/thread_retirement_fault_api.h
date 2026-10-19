#ifndef TITAN_THREAD_RETIREMENT_FAULT_API_H
#define TITAN_THREAD_RETIREMENT_FAULT_API_H

#include "lua.h"

enum titan_thread_fault_counter {
  TITAN_THREAD_FAULT_CREATED = 1,
  TITAN_THREAD_FAULT_CHILD_CLEANUP,
  TITAN_THREAD_FAULT_ENTRY_RETURNED,
  TITAN_THREAD_FAULT_TAIL_RELEASED,
  TITAN_THREAD_FAULT_JOIN_ATTEMPTS,
  TITAN_THREAD_FAULT_JOIN_FAILURES,
  TITAN_THREAD_FAULT_REAL_JOINS,
  TITAN_THREAD_FAULT_TERMINALS,
  TITAN_THREAD_FAULT_EARLY_TERMINALS,
  TITAN_THREAD_FAULT_CHANGED_TOKEN,
  TITAN_THREAD_FAULT_STACK_GROWTH,
  TITAN_THREAD_FAULT_ALLOCATOR_HITS,
  TITAN_THREAD_FAULT_USERDATA_ENTRY,
  TITAN_THREAD_FAULT_ALLOCATION_BYTES,
  TITAN_THREAD_FAULT_WIDE_BODY,
  TITAN_THREAD_FAULT_FORWARD_HOOK,
  TITAN_THREAD_FAULT_PACKET_COPY_FAILURES,
  TITAN_THREAD_FAULT_CHILD_STARTED,
  TITAN_THREAD_FAULT_LISTENER_RETURN_FAILURES,
  TITAN_THREAD_FAULT_LISTENER_REGISTRATION_FAILURES,
  TITAN_THREAD_FAULT_MAP_ADMISSION_FAILURES,
  TITAN_THREAD_FAULT_CREATE_FAILURES
};

/* One fresh process owns this C-heap domain. Only the owning Lua OS thread
 * inspects Lua allocation state; workers use native gates only. */
int titan_thread_fault_init(lua_State *state);
void titan_thread_fault_arm_worker(void);
void titan_thread_fault_arm_worker_entry_gate(void);
void titan_thread_fault_arm_finished_before_create_return(void);
void titan_thread_fault_release_worker_entry(void);
void titan_thread_fault_wait_started(void);
void titan_thread_fault_wait_cleanup(void);
void titan_thread_fault_child_started(void);
void titan_thread_fault_child_cleanup(void);
void titan_thread_fault_release_cleanup(void);
void titan_thread_fault_terminal(void);
void titan_thread_fault_fail_join_once(void);
int titan_thread_fault_join_error(void);
void titan_thread_fault_arm_userdata_oom(void);
void titan_thread_fault_arm_stack_oom(lua_State *state);
void titan_thread_fault_begin_packet_probe(void);
int titan_thread_fault_finish_packet_probe(const void *message);
void titan_thread_fault_arm_packet_copy_oom(void);
void titan_thread_fault_begin_listener_probe(void);
int titan_thread_fault_finish_listener_probe(void);
void titan_thread_fault_arm_listener_return_oom(void);
void titan_thread_fault_arm_listener_registration_oom(void);
void titan_thread_fault_begin_map_probe(void);
int titan_thread_fault_finish_map_probe(void);
void titan_thread_fault_arm_map_admission_oom(void);
void titan_thread_fault_fail_create_once(void);
int titan_thread_fault_create_error(void);
void titan_thread_fault_wide_body(void);
void titan_thread_fault_forward_hook(void);
void *titan_thread_fault_context(void);
void titan_thread_fault_set_wake_functions(void (*retain)(void *),
                                         int (*notify)(void *),
                                         void (*release)(void *));
int titan_thread_fault_start_native(void);
void titan_thread_fault_release_native(void);
int titan_thread_fault_register(void *context, void *target);
void titan_thread_fault_unregister(void *context);
int titan_thread_fault_retire(void *context);
void titan_thread_fault_disarm(void);
int titan_thread_fault_counter(int counter);
const char *titan_thread_fault_memory_error(lua_State *state);
void titan_thread_fault_report(void);
void titan_thread_fault_shutdown(void);

#endif
