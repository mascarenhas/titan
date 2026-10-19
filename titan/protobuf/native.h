#ifndef TITAN_PROTOBUF_NATIVE_H
#define TITAN_PROTOBUF_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct titan_protobuf_buffer titan_protobuf_buffer;

typedef int (*titan_protobuf_grow_fn)(
    titan_protobuf_buffer *buf, size_t min_capacity);

struct titan_protobuf_buffer {
  uint8_t *data;
  size_t length;
  size_t capacity;
  void *context;
  titan_protobuf_grow_fn grow;
};

static inline int titan_protobuf_heap_grow(
    titan_protobuf_buffer *buf, size_t min_capacity) {
  uint8_t *next = (uint8_t *)realloc(buf->data, min_capacity);
  if (next == NULL) {
    return 0;
  }
  buf->data = next;
  buf->capacity = min_capacity;
  return 1;
}

static inline int titan_protobuf_buf_reserve(
    titan_protobuf_buffer *buf, size_t extra) {
  if (extra <= buf->capacity - buf->length) {
    return 1;
  }
  if (extra > SIZE_MAX - buf->length) {
    return 0;
  }
  size_t needed = buf->length + extra;
  size_t new_cap = buf->capacity;
  if (new_cap < 64) {
    new_cap = 64;
  }
  if (new_cap <= SIZE_MAX / 4 && extra > new_cap * 4) {
    /* A single bulk write should not retain the next power-of-two block.
     * Leave bounded room for later fields, packet metadata and attachments.
     * Near the size limit the slack does not fit, so request exactly what the
     * caller needs instead of an unrepresentable extra 256 bytes. */
    if (needed <= SIZE_MAX - 256) {
      new_cap = needed + 256;
    } else {
      new_cap = needed;
    }
  } else {
    while (new_cap < needed) {
      if (new_cap > SIZE_MAX / 2) {
        new_cap = needed;
        break;
      }
      new_cap *= 2;
    }
  }
  if (buf->grow == NULL) {
    return 0;
  }
  return buf->grow(buf, new_cap);
}

static inline void titan_protobuf_buf_init(
    titan_protobuf_buffer *buf,
    uint8_t *data,
    size_t length,
    size_t capacity,
    void *context,
    titan_protobuf_grow_fn grow) {
  buf->data = data;
  buf->length = length;
  buf->capacity = capacity;
  buf->context = context;
  buf->grow = grow;
}

static inline int titan_protobuf_buf_init_heap(
    titan_protobuf_buffer *buf, size_t prefix_size) {
  titan_protobuf_buf_init(buf, NULL, 0, 0, NULL, titan_protobuf_heap_grow);
  if (prefix_size > 0) {
    if (!titan_protobuf_buf_reserve(buf, prefix_size)) {
      return 0;
    }
    memset(buf->data, 0, prefix_size);
    buf->length = prefix_size;
  }
  return 1;
}

static inline void titan_protobuf_buf_free_heap(titan_protobuf_buffer *buf) {
  if (buf->data != NULL) {
    free(buf->data);
    buf->data = NULL;
  }
  buf->length = 0;
  buf->capacity = 0;
}

static inline uint8_t *titan_protobuf_buf_take_data(titan_protobuf_buffer *buf) {
  uint8_t *data = buf->data;
  buf->data = NULL;
  buf->length = 0;
  buf->capacity = 0;
  return data;
}

static inline int titan_protobuf_buf_write_varint(
    titan_protobuf_buffer *buf, int64_t bits) {
  if (!titan_protobuf_buf_reserve(buf, 10)) {
    return 0;
  }
  uint64_t remaining = (uint64_t)bits;
  uint8_t *out = buf->data + buf->length;
  while (remaining >= 128) {
    *out++ = (uint8_t)((remaining & 127) | 128);
    remaining >>= 7;
  }
  *out++ = (uint8_t)remaining;
  buf->length = (size_t)(out - buf->data);
  return 1;
}

static inline int titan_protobuf_buf_write_raw(
    titan_protobuf_buffer *buf, const char *bytes, size_t len) {
  if (len == 0) {
    return 1;
  }
  if (!titan_protobuf_buf_reserve(buf, len)) {
    return 0;
  }
  memcpy(buf->data + buf->length, bytes, len);
  buf->length += len;
  return 1;
}

static inline int titan_protobuf_buf_write_bytes(
    titan_protobuf_buffer *buf, int64_t key_bits, const char *bytes, size_t len) {
  if (!titan_protobuf_buf_write_varint(buf, key_bits)) {
    return 0;
  }
  if (!titan_protobuf_buf_write_varint(buf, (int64_t)len)) {
    return 0;
  }
  return titan_protobuf_buf_write_raw(buf, bytes, len);
}

static inline int titan_protobuf_buf_write_fixed64(
    titan_protobuf_buffer *buf, int64_t key_bits, int64_t value_bits) {
  if (!titan_protobuf_buf_write_varint(buf, key_bits)) {
    return 0;
  }
  if (!titan_protobuf_buf_reserve(buf, 8)) {
    return 0;
  }
  uint64_t u = (uint64_t)value_bits;
  uint8_t *out = buf->data + buf->length;
  out[0] = (uint8_t)(u);
  out[1] = (uint8_t)(u >> 8);
  out[2] = (uint8_t)(u >> 16);
  out[3] = (uint8_t)(u >> 24);
  out[4] = (uint8_t)(u >> 32);
  out[5] = (uint8_t)(u >> 40);
  out[6] = (uint8_t)(u >> 48);
  out[7] = (uint8_t)(u >> 56);
  buf->length += 8;
  return 1;
}

static inline int titan_protobuf_buf_write_double(
    titan_protobuf_buffer *buf, int64_t key_bits, double value) {
  int64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return titan_protobuf_buf_write_fixed64(buf, key_bits, bits);
}

static inline int titan_protobuf_buf_write_float32(
    titan_protobuf_buffer *buf, int64_t key_bits, double value) {
  if (!titan_protobuf_buf_write_varint(buf, key_bits)) {
    return 0;
  }
  if (!titan_protobuf_buf_reserve(buf, 4)) {
    return 0;
  }
  float f = (float)value;
  uint32_t u;
  memcpy(&u, &f, sizeof(u));
  uint8_t *out = buf->data + buf->length;
  out[0] = (uint8_t)(u);
  out[1] = (uint8_t)(u >> 8);
  out[2] = (uint8_t)(u >> 16);
  out[3] = (uint8_t)(u >> 24);
  buf->length += 4;
  return 1;
}

static inline int64_t titan_protobuf_buf_begin_nested(
    titan_protobuf_buffer *buf, int64_t key_bits) {
  if (!titan_protobuf_buf_write_varint(buf, key_bits)) {
    return -1;
  }
  if (!titan_protobuf_buf_reserve(buf, 1)) {
    return -1;
  }
  size_t mark = buf->length;
  buf->data[mark] = 0;
  buf->length = mark + 1;
  return (int64_t)mark;
}

static inline int titan_protobuf_buf_end_nested(
    titan_protobuf_buffer *buf, int64_t mark_idx) {
  size_t mark = (size_t)mark_idx;
  size_t payload_len = buf->length - (mark + 1);
  if (payload_len > 2147483647ULL) {
    return -1;
  }
  if (payload_len < 128) {
    buf->data[mark] = (uint8_t)payload_len;
    return 1;
  }
  size_t vlen = 1;
  size_t temp = payload_len;
  while (temp >= 128) {
    vlen++;
    temp >>= 7;
  }
  size_t extra = vlen - 1;
  if (!titan_protobuf_buf_reserve(buf, extra)) {
    return 0;
  }
  memmove(buf->data + mark + vlen, buf->data + mark + 1, payload_len);
  temp = payload_len;
  uint8_t *out = buf->data + mark;
  while (temp >= 128) {
    *out++ = (uint8_t)((temp & 127) | 128);
    temp >>= 7;
  }
  *out = (uint8_t)temp;
  buf->length += extra;
  return 1;
}

static inline const uint8_t *titan_protobuf_bytes_ptr(const char *s) {
  return (const uint8_t *)s;
}

static inline const char *titan_protobuf_offset_ptr(
    const uint8_t *base, size_t offset) {
  return (const char *)(base + offset);
}

static inline int64_t titan_protobuf_read_fixed64(
    const uint8_t *base, size_t offset) {
  const uint8_t *p = base + offset;
  uint64_t u = ((uint64_t)p[0]) |
               ((uint64_t)p[1] << 8) |
               ((uint64_t)p[2] << 16) |
               ((uint64_t)p[3] << 24) |
               ((uint64_t)p[4] << 32) |
               ((uint64_t)p[5] << 40) |
               ((uint64_t)p[6] << 48) |
               ((uint64_t)p[7] << 56);
  int64_t result;
  memcpy(&result, &u, sizeof(result));
  return result;
}

static inline double titan_protobuf_read_double(
    const uint8_t *base, size_t offset) {
  int64_t bits = titan_protobuf_read_fixed64(base, offset);
  double result;
  memcpy(&result, &bits, sizeof(result));
  return result;
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

