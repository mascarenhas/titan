#ifndef TITAN_THREAD_NATIVE_H
#define TITAN_THREAD_NATIVE_H

#include <stddef.h>
#include "lua.h"
#include "titan/ffi.h"
#include "../transfer_native.h"

/* The CRT write count is unsigned int on Windows and size_t on POSIX. */
#ifdef _WIN32
typedef unsigned int titan_thread_write_count;
#else
typedef size_t titan_thread_write_count;
#endif

/* Native layouts for cross-state channels and OS-thread lifecycles.
 * Shareable channel/control structures live on the process heap and are
 * synchronized by borrowed native uv_mutex_t capabilities. Wait contexts are
 * call-scoped automatic storage; no GC objects cross states. */
typedef struct titan_thread_channel titan_thread_channel;
typedef titan_async_message titan_thread_message;
typedef titan_thread_message *titan_thread_message_ptr;

/* A registered waiter holds one pin on its domain (channel or thread control
 * block) from waiter_enqueue while it is linked (active) or woken but not yet
 * acknowledged by its own Task (signaled). The pin defers domain destruction,
 * so the stack-resident node can always be withdrawn under the domain mutex,
 * including during lua_close after the traced endpoint was finalized. */
typedef struct titan_thread_waiter {
  struct titan_thread_waiter *next;
  struct titan_thread_waiter *prev;
  void *wake_target;
  int signaled;
  int active;
} titan_thread_waiter;

typedef struct titan_thread_waiter_queue {
  titan_thread_waiter *head;
  titan_thread_waiter *tail;
} titan_thread_waiter_queue;

/* One suspended channel call owns this automatic frame until its external wait
 * returns or synchronously unlinks on cancellation. The bridge roots the
 * endpoint; producers only access waiter under the channel mutex. */
typedef struct titan_thread_channel_wait {
  titan_thread_channel *channel;
  titan_thread_message *message;
  titan_thread_waiter waiter;
  int status;
} titan_thread_channel_wait;

/* Titan's mutable address coercion accepts locals/formals, not struct fields. */
static inline titan_thread_waiter *titan_thread_channel_waiter(
    titan_thread_channel_wait *wait) {
  return &wait->waiter;
}

/* Implementation notes: doc/implementation/thread-library.md#channel-state-machine-and-endpoint-transfer */
struct titan_thread_channel {
  void *mutex;
  size_t active_senders;
  size_t active_receivers;
  /* Registrations pinning this channel; see titan_thread_waiter. */
  size_t waiter_pins;
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

typedef enum titan_thread_cancellation_kind {
  TITAN_THREAD_CANCELLATION_DEFAULT,
  TITAN_THREAD_CANCELLATION_SIMPLE,
  TITAN_THREAD_CANCELLATION_COMPLEX
} titan_thread_cancellation_kind;

typedef struct titan_thread_control {
  void *mutex;
  /* Handles, the worker and each join registration's pin. */
  size_t refcount;
  void *os_thread;
  int os_joined;
  /* One cached Thread:task monitor owns this native, non-GC waiter slot. */
  void *proxy_wake_target;
  lua_State *child_state;
  titan_thread_message *entry_msg;
  int cancel_requested;
  titan_thread_message *cancel_reason_msg;
  int cancel_reason_kind;
  void *child_cancel_handle;
  int finished;
  titan_thread_state_kind status_kind;
  titan_thread_message *result_msg;
  int result_reason_kind;
  char *error_traceback;
  size_t error_traceback_len;
  char *stderr_report;
  size_t stderr_report_len;
  int observed;
  int abandoned;
  titan_thread_waiter_queue join_waiters;
} titan_thread_control;

/* One suspended Thread join owns this automatic frame like a channel wait. */
typedef struct titan_thread_join_wait {
  titan_thread_control *control;
  titan_thread_waiter waiter;
} titan_thread_join_wait;

static inline titan_thread_waiter *titan_thread_join_waiter(
    titan_thread_join_wait *wait) {
  return &wait->waiter;
}

static inline size_t *titan_thread_channel_pins(titan_thread_channel *ch) {
  return &ch->waiter_pins;
}

static inline size_t *titan_thread_control_pins(titan_thread_control *ctrl) {
  return &ctrl->refcount;
}

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

#endif
