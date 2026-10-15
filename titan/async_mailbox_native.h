#ifndef TITAN_ASYNC_MAILBOX_NATIVE_H
#define TITAN_ASYNC_MAILBOX_NATIVE_H

#include <stddef.h>
#include "lua.h"

/* Only native bytes cross a state/thread boundary. The public UV binding owns
 * the actual async handle and mutex; these are its borrowed C-only capabilities.
 * The Receiver retains those owners through every send and native close. */
typedef enum titan_async_message_kind {
  TITAN_ASYNC_MESSAGE_NIL,
  TITAN_ASYNC_MESSAGE_BOOLEAN,
  TITAN_ASYNC_MESSAGE_INTEGER,
  TITAN_ASYNC_MESSAGE_FLOAT,
  TITAN_ASYNC_MESSAGE_STRING,
  TITAN_ASYNC_MESSAGE_STATE,
  TITAN_ASYNC_MESSAGE_FUNCTION,
  TITAN_ASYNC_MESSAGE_POINTER
} titan_async_message_kind;

typedef struct titan_async_message {
  struct titan_async_message *next;
  titan_async_message_kind kind;
  lua_Integer integer;
  lua_Number number;
  const char *bytes;
  size_t length;
  lua_State *state;
  lua_CFunction function;
  void *pointer;
} titan_async_message;

typedef struct titan_async_mailbox {
  void *handle;
  void *mutex;
  int (*send)(void *);
  void (*lock)(void *);
  void (*unlock)(void *);
  titan_async_message *first;
  titan_async_message *last;
  int closed;
} titan_async_mailbox;

#endif
