#ifndef TITAN_ASYNC_RECEIVER_NATIVE_H
#define TITAN_ASYNC_RECEIVER_NATIVE_H

#include <stddef.h>
#include "lua.h"
#include "titan/ffi.h"

/* Only native bytes cross a state/thread boundary. The public UV binding owns
 * the async handle; its borrowed C-only send capability never enters Lua.
 * Callers finish sends before close and retain the Receiver through all uses. */
typedef enum titan_async_message_kind {
  TITAN_ASYNC_MESSAGE_NIL,
  TITAN_ASYNC_MESSAGE_BOOLEAN,
  TITAN_ASYNC_MESSAGE_INTEGER,
  TITAN_ASYNC_MESSAGE_FLOAT,
  TITAN_ASYNC_MESSAGE_STRING,
  TITAN_ASYNC_MESSAGE_STATE,
  TITAN_ASYNC_MESSAGE_FUNCTION,
  TITAN_ASYNC_MESSAGE_POINTER,
  TITAN_ASYNC_MESSAGE_RECORD,
  TITAN_ASYNC_MESSAGE_UNION,
  TITAN_ASYNC_MESSAGE_CLOSURE,
  TITAN_ASYNC_MESSAGE_RECORD_PAYLOAD
} titan_async_message_kind;

typedef struct titan_async_message {
  titan_async_message_kind kind;
  lua_Integer integer;
  lua_Number number;
  const char *bytes;
  size_t length;
  const char *name;
  size_t name_length;
  const char *module;
  size_t module_length;
  lua_State *state;
  lua_CFunction function;
  void *pointer;
  const void *entry;
} titan_async_message;

typedef struct titan_async_receiver {
  void *handle;
  int (*send)(void *);
  titan_async_message *message;
  int closed;
} titan_async_receiver;

/* Titan's FFI cannot spell the compiler's generic atomic builtin. The supported
 * GCC/Clang toolchains provide this exchange on a naturally aligned pointer.
 * Publication transfers ownership: only the thread taking the old pointer may
 * read/free it. Close is externally serialized with send, like handle lifetime. */
static inline titan_async_message *titan_async_receiver_exchange(
    titan_async_receiver *receiver, titan_async_message *message) {
  return __atomic_exchange_n(&receiver->message, message, __ATOMIC_ACQ_REL);
}

#endif
