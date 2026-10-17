#ifndef TITAN_ASYNC_RECEIVER_NATIVE_H
#define TITAN_ASYNC_RECEIVER_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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

static inline titan_async_message *titan_async_copy_message(
    const titan_async_message *input) {
  size_t length = 0;
  size_t name_length = 0;
  size_t module_length = 0;
  if (input->kind == TITAN_ASYNC_MESSAGE_STRING) {
    length = input->length;
  } else if (input->kind == TITAN_ASYNC_MESSAGE_RECORD ||
             input->kind == TITAN_ASYNC_MESSAGE_UNION ||
             input->kind == TITAN_ASYNC_MESSAGE_CLOSURE ||
             input->kind == TITAN_ASYNC_MESSAGE_RECORD_PAYLOAD) {
    length = input->length;
    name_length = input->name_length;
    module_length = input->module_length;
  }
  if (length > SIZE_MAX - sizeof(titan_async_message)) return NULL;
  if (name_length > SIZE_MAX - sizeof(titan_async_message) - length) return NULL;
  if (module_length > SIZE_MAX - sizeof(titan_async_message) - length - name_length) {
    return NULL;
  }
  titan_async_message *message = (titan_async_message *)malloc(
      sizeof(titan_async_message) + length + name_length + module_length);
  if (message == NULL) return NULL;
  *message = *input;
  char *bytes = (char *)(message + 1);
  message->bytes = bytes;
  if (length > 0) {
    memcpy(bytes, input->bytes, length);
  }
  message->name = bytes + length;
  if (name_length > 0) {
    memcpy(bytes + length, input->name, name_length);
  }
  message->module = bytes + length + name_length;
  if (module_length > 0) {
    memcpy(bytes + length + name_length, input->module, module_length);
  }
  return message;
}

/* Titan's FFI cannot spell the compiler's generic atomic builtin. The supported
 * GCC/Clang toolchains provide this exchange on a naturally aligned pointer.
 * Publication transfers ownership: only the thread taking the old pointer may
 * read/free it. Close is externally serialized with send, like handle lifetime. */
static inline titan_async_message *titan_async_receiver_exchange(
    titan_async_receiver *receiver, titan_async_message *message) {
  return __atomic_exchange_n(&receiver->message, message, __ATOMIC_ACQ_REL);
}

#endif
