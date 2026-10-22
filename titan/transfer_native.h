#ifndef TITAN_TRANSFER_NATIVE_H
#define TITAN_TRANSFER_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "titan/ffi.h"

/* Rebuild every provider/consumer when this native packet contract changes.
 * Attachment payloads are exactly four little-endian bytes: indexes
 * 0..0xfffffffe name current-packet entries; 0xffffffff is never valid.
 * Entries contain native data only. Their callbacks must not enter Lua. */
#define TITAN_TRANSFER_PACKET_VERSION 1
#define TITAN_TRANSFER_INVALID_INDEX UINT32_MAX
#define TITAN_TRANSFER_INLINE_RESOURCES 4

typedef void (*titan_transfer_resource_fn)(void *);

/* A NULL resource marks a consumed unit; keep release for kind-before-duplicate
 * claim validation. Committed entries live in the packet's aligned tail. */
typedef struct titan_transfer_resource {
  void *resource;
  titan_transfer_resource_fn release;
} titan_transfer_resource;

/* Implementation notes: doc/implementation/transfer-library.md#packet-scoped-resource-table-titan_transfer_resource_table */
/* Committed packets retain an exact count, never scratch capacity. Their entry
 * pointer is NULL for zero entries and otherwise points inside the packet. */
typedef struct titan_transfer_resource_table {
  titan_transfer_resource *entries;
  size_t count;
} titan_transfer_resource_table;

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
  titan_transfer_resource_table resources;
} titan_async_message;

/* Scratch is confined to this traced native cell. Capacity zero is inert;
 * capacity == INLINE_RESOURCES selects inline_entries, larger capacity selects
 * a heap spill. Retirement frees the spill and zeroes the complete cell. */
typedef struct titan_transfer_scope_owner {
  titan_transfer_resource_table resources;
  size_t capacity;
  titan_async_message *message;
  titan_transfer_resource inline_entries[TITAN_TRANSFER_INLINE_RESOURCES];
} titan_transfer_scope_owner;

/* Titan's FFI cannot take the mutable address of a C aggregate field on a
 * pointer expression. Keep only that address operation in the header. */
static inline titan_transfer_resource_table *titan_transfer_message_resources(
    titan_async_message *message) {
  return &message->resources;
}

static inline titan_transfer_resource_table *titan_transfer_scope_resources(
    titan_transfer_scope_owner *owner) {
  return &owner->resources;
}

#endif
