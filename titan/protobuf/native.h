#ifndef TITAN_PROTOBUF_NATIVE_H
#define TITAN_PROTOBUF_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The wire buffer, its writers, and the fixed64/double readers are SDK
 * primitives in transfer.h: compiler-generated nominal codecs in every module
 * append through them. This header keeps the reflective decoder's directory
 * entry and its remaining C-only helpers. */
#include "transfer.h"

/* Decoder entries contain only native bits and byte offsets, never GC values.
 * One entry is embedded in Message; larger directories use counted GC owners.
 * `previous` links earlier same-number occurrences, while `chain` links the
 * latest entries of distinct numbers sharing one index bucket. */
typedef struct titan_protobuf_field {
  uint32_t number;
  uint32_t wire;
  int64_t bits;
  uint32_t offset;
  uint32_t length;
  uint32_t previous;
  uint32_t chain;
} titan_protobuf_field;

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
