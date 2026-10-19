#ifndef TITAN_SPEC_PROTOBUF_FIXTURE_H
#define TITAN_SPEC_PROTOBUF_FIXTURE_H

/* Use the authoritative raw-buffer collaboration contract, not a layout mirror. */
#include "../../../../titan/protobuf/native.h"
typedef int titan_protobuf_row[1 + 2];

typedef struct titan_protobuf_pair {
  int x;
  unsigned long long serial;
  float ratio;
} titan_protobuf_pair;

typedef struct titan_protobuf_packet {
  titan_protobuf_pair pair;
  titan_protobuf_row row;
  void *pointer;
  unsigned int mode : 3;
  signed int offset : 5;
} titan_protobuf_packet;

static inline long double titan_protobuf_long_double(void) {
  return 0x1.000000000000001p0L;
}

static inline int titan_protobuf_increment(int value) {
  return value + 1;
}

/* Synthetic addresses are compared and serialized, never dereferenced. */
static inline void *titan_protobuf_pointer_pattern(int64_t value) {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return (void *)(uintptr_t)bits;
}

#endif
