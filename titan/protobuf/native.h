#ifndef TITAN_PROTOBUF_NATIVE_H
#define TITAN_PROTOBUF_NATIVE_H

#include <stdint.h>
#include <string.h>

/* Titan's checked numeric casts intentionally do not expose pointer/integer
 * reinterpretation. Keep that operation, and only that operation, here. */
static inline int64_t titan_protobuf_pointer_bits(void *address) {
  uint64_t bits = (uint64_t)(uintptr_t)address;
  int64_t result;
  memcpy(&result, &bits, sizeof(result));
  return result;
}

static inline void *titan_protobuf_bits_pointer(int64_t value) {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return (void *)(uintptr_t)bits;
}

#endif
