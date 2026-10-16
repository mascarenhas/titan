#ifndef TITAN_SPEC_PROTOBUF_FIXTURE_H
#define TITAN_SPEC_PROTOBUF_FIXTURE_H

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

#endif
