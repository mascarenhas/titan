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

static inline const uint8_t *titan_protobuf_bytes_ptr(const char *s) {
  return (const uint8_t *)s;
}

static inline const char *titan_protobuf_offset_ptr(
    const uint8_t *base, size_t offset) {
  return (const char *)(base + offset);
}

static inline double titan_protobuf_read_float32(
    const uint8_t *base, size_t offset) {
  const uint8_t *p = base + offset;
  uint32_t u = ((uint32_t)p[0]) |
               ((uint32_t)p[1] << 8) |
               ((uint32_t)p[2] << 16) |
               ((uint32_t)p[3] << 24);
  float f;
  memcpy(&f, &u, sizeof(f));
  return (double)f;
}

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
