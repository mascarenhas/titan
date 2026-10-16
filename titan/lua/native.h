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
} titan_lua_call;

#endif
