#ifndef TITAN_THREAD_NATIVE_H
#define TITAN_THREAD_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "titan/ffi.h"
#include "../async_receiver_native.h"

/* Native layouts for cross-state channels and OS-thread lifecycles.
 * All structures live on the process heap and are synchronized by borrowed
 * native uv_mutex_t capabilities without exposing one state's GC objects. */
typedef struct titan_thread_channel titan_thread_channel;
typedef titan_async_message titan_thread_message;
typedef titan_thread_message *titan_thread_message_ptr;

typedef struct titan_thread_waiter {
  struct titan_thread_waiter *next;
  struct titan_thread_waiter *prev;
  void *async_handle;
  int signaled;
  int active;
} titan_thread_waiter;

typedef struct titan_thread_waiter_queue {
  titan_thread_waiter *head;
  titan_thread_waiter *tail;
} titan_thread_waiter_queue;

struct titan_thread_channel {
  void *mutex;
  size_t active_senders;
  size_t active_receivers;
  size_t capacity;
  size_t head;
  size_t tail;
  size_t count;
  titan_thread_message_ptr *ring;
  titan_thread_waiter_queue overflow_waiters;
  titan_thread_waiter_queue underflow_waiters;
  int closed;
};

typedef enum titan_thread_state_kind {
  TITAN_THREAD_STATE_RUNNING,
  TITAN_THREAD_STATE_SUCCEEDED,
  TITAN_THREAD_STATE_FAILED,
  TITAN_THREAD_STATE_CANCELLED
} titan_thread_state_kind;

typedef struct titan_thread_control {
  void *mutex;
  size_t refcount;
  lua_State *child_state;
  titan_thread_message *entry_msg;
  int cancel_requested;
  titan_thread_message *cancel_reason_msg;
  void *child_cancel_handle;
  int finished;
  titan_thread_state_kind status_kind;
  titan_thread_message *result_msg;
  char *error_traceback;
  size_t error_traceback_len;
  char *stderr_report;
  size_t stderr_report_len;
  int observed;
  titan_thread_waiter_queue join_waiters;
} titan_thread_control;

static inline titan_thread_waiter_queue *titan_thread_overflow_queue(
    titan_thread_channel *ch) {
  return &ch->overflow_waiters;
}

static inline titan_thread_waiter_queue *titan_thread_underflow_queue(
    titan_thread_channel *ch) {
  return &ch->underflow_waiters;
}

static inline titan_thread_waiter_queue *titan_thread_join_queue(
    titan_thread_control *ctrl) {
  return &ctrl->join_waiters;
}

static inline int64_t titan_thread_pointer_bits(void *address) {
  uint64_t bits = (uint64_t)(uintptr_t)address;
  int64_t result;
  memcpy(&result, &bits, sizeof(result));
  return result;
}

static inline void *titan_thread_bits_pointer(int64_t value) {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return (void *)(uintptr_t)bits;
}

#endif
