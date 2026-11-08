#ifndef TITAN_ASYNC_RECEIVER_NATIVE_H
#define TITAN_ASYNC_RECEIVER_NATIVE_H

#include "../transfer_native.h"

/* Only native bytes cross a state/thread boundary. The public UV binding owns
 * the async handle; its borrowed C-only send capability never enters Lua.
 * Callers finish sends before close and retain the Receiver through all uses. */

typedef struct titan_async_receiver {
  void *handle;
  int (*send)(void *);
  titan_async_message *message;
  int closed;
} titan_async_receiver;

/* Loop-thread-only native retirement state. No producer keeps a pointer into
 * this GC-owned cell; producers retain the UV target's independent native core. */
typedef struct titan_async_retirement {
  void *context;
  int (*register_wait)(void *, void *);
  void (*unregister_wait)(void *);
  int (*retire)(void *);
  int armed;
  int ready;
  int status;
} titan_async_retirement;


/* Titan's FFI cannot spell the compiler's generic atomic builtin. The supported
 * GCC/Clang toolchains provide this exchange on a naturally aligned pointer.
 * Publication transfers ownership: only the thread taking the old pointer may
 * read/free it. Close is externally serialized with send, like handle lifetime. */
static inline titan_async_message *titan_async_receiver_exchange(
    titan_async_receiver *receiver, titan_async_message *message) {
  return __atomic_exchange_n(&receiver->message, message, __ATOMIC_ACQ_REL);
}

#endif
