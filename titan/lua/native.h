#ifndef TITAN_LUA_NATIVE_H
#define TITAN_LUA_NATIVE_H

#include <stddef.h>
#include "lua.h"
#include "titan/ffi.h"

/* Titan's FFI imports aggregate declarations but does not declare C layouts.
 * These carriers contain only native data. String bytes are borrowed from a
 * rooted origin until completion; they never expose that origin's GC objects. */
typedef enum titan_lua_kind {
  TITAN_LUA_NIL,
  TITAN_LUA_BOOLEAN,
  TITAN_LUA_INTEGER,
  TITAN_LUA_FLOAT,
  TITAN_LUA_STRING,
  TITAN_LUA_STATE,
  TITAN_LUA_FUNCTION,
  TITAN_LUA_POINTER,
  TITAN_LUA_RECORD,
  TITAN_LUA_UNION,
  TITAN_LUA_CLOSURE,
  TITAN_LUA_RECORD_PAYLOAD
} titan_lua_kind;

typedef struct titan_lua_value {
  titan_lua_kind kind;
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
} titan_lua_value;

typedef struct titan_lua_preload {
  const char *name;
  size_t length;
  lua_CFunction loader;
  TitanModuleSymbols symbols;
} titan_lua_preload;

typedef struct titan_lua_open {
  lua_State *state;
  const titan_lua_preload *preloads;
  int count;
} titan_lua_open;

typedef struct titan_lua_call {
  lua_State *state;
  const char *chunk;
  const char *name;
  size_t length;
  int nargs;
  int status;
  int nresults;
  titan_lua_value *args;
  /* Allocated by the worker; freed by the caller only after completion. */
  titan_lua_value *results;
  const char *message;
  size_t message_length;
  /* An asynchronous run's worker and an abandoning host-state close each
   * exchange their side in; whichever finds the other's mark releases the
   * results and closes the independent state. */
  int handoff;
} titan_lua_call;

#define TITAN_LUA_WORKER_FINISHED 1
#define TITAN_LUA_WORKER_ABANDONED 2

/* Implementation notes: doc/implementation/lua-library.md#host-state-close-during-run_async */
/* Titan's FFI cannot spell the compiler's generic atomic builtin. */
static inline int titan_lua_call_handoff(titan_lua_call *call, int side) {
  return __atomic_exchange_n(&call->handoff, side, __ATOMIC_ACQ_REL);
}

#endif
