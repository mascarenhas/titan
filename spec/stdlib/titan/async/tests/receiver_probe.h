#ifndef TITAN_ASYNC_RECEIVER_PROBE_H
#define TITAN_ASYNC_RECEIVER_PROBE_H

#include <stddef.h>
#include <string.h>

/* Only the notification prefix of the borrowed receiver handle is replaced.
 * Byte copies avoid aliasing the production slot through a different C struct
 * type. This fixture neither exchanges nor disposes the production packet. */
typedef struct titan_receiver_notification_prefix {
  void *handle;
  int (*send)(void *);
} titan_receiver_notification_prefix;

typedef struct titan_receiver_send_guard {
  unsigned char *slot;
  void *original_handle;
  int (*original_send)(void *);
  int fail_code;
  int calls;
} titan_receiver_send_guard;

static inline int titan_receiver_probe_send(void *raw_guard) {
  titan_receiver_send_guard *guard =
      (titan_receiver_send_guard *)raw_guard;
  guard->calls++;
  int status = guard->original_send(guard->original_handle);
  /* Preserve the accepted notification's real completion/liveness obligation.
   * Only its returned error boundary belongs to this test fixture. */
  return status != 0 ? status : guard->fail_code;
}

static inline void titan_receiver_guard_install(
    titan_receiver_send_guard *guard,
    void *raw_handle,
    int fail_code) {
  unsigned char *slot = (unsigned char *)raw_handle;
  guard->slot = slot;
  memcpy(&guard->original_handle,
         slot + offsetof(titan_receiver_notification_prefix, handle),
         sizeof(guard->original_handle));
  memcpy(&guard->original_send,
         slot + offsetof(titan_receiver_notification_prefix, send),
         sizeof(guard->original_send));
  guard->fail_code = fail_code;
  guard->calls = 0;
  void *probe_handle = guard;
  int (*probe_send)(void *) = titan_receiver_probe_send;
  memcpy(slot + offsetof(titan_receiver_notification_prefix, handle),
         &probe_handle, sizeof(probe_handle));
  memcpy(slot + offsetof(titan_receiver_notification_prefix, send),
         &probe_send, sizeof(probe_send));
}

static inline void titan_receiver_guard_restore(
    titan_receiver_send_guard *guard) {
  if (guard != NULL && guard->slot != NULL) {
    memcpy(guard->slot + offsetof(titan_receiver_notification_prefix, handle),
           &guard->original_handle, sizeof(guard->original_handle));
    memcpy(guard->slot + offsetof(titan_receiver_notification_prefix, send),
           &guard->original_send, sizeof(guard->original_send));
    guard->slot = NULL;
  }
}

static inline int titan_receiver_guard_calls(
    const titan_receiver_send_guard *guard) {
  return guard != NULL ? guard->calls : 0;
}
/* A separate, loop-thread-only native retirement domain. Its C-only callbacks
 * live in external_wait_test.native.titan and use only public UV wake capabilities.
 * No production state layout, allocator, epoch, or callback is modified. */
typedef struct titan_external_retirement_fixture {
  void *target;
  int ready;
  int retired;
  int register_calls;
  int unregister_calls;
  int retire_calls;
  int retirements;
  int register_error;
  int retire_error;
} titan_external_retirement_fixture;

#endif
