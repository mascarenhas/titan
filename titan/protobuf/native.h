#ifndef TITAN_PROTOBUF_NATIVE_H
#define TITAN_PROTOBUF_NATIVE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

/* Per-root automatic scratch, never part of a GC buffer or a native packet.
 * Entries are in opening order; zero vlen denotes an unfinished message.
 * Beyond this bound, finish the pending patches once and use eager widening
 * until the outermost message closes. No encoder or hook is replayed.
 * extra_before is at most 31 earlier prefixes times four added bytes (124),
 * fitting uint16_t. The uint8_t fields hold a parent index or sentinel 32 and
 * a varint width of at most five bytes under the 2 GiB message limit. */
#define TITAN_PROTOBUF_BACKPATCH_LIMIT 32
typedef struct titan_protobuf_patch {
  size_t mark;
  uint32_t payload_len;
  uint16_t extra_before;
  uint8_t parent;
  uint8_t vlen;
} titan_protobuf_patch;

typedef struct titan_protobuf_backpatch {
  size_t extra;
  unsigned int count;
  unsigned int depth;
  unsigned int fallback_depth; /* depth of innermost pre-fallback frame */
  unsigned int active;         /* innermost still-open tracked entry */
  titan_protobuf_patch entries[TITAN_PROTOBUF_BACKPATCH_LIMIT];
} titan_protobuf_backpatch;

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
     * Leave max(256, needed / 8) bytes for later fields, packet metadata and
     * attachments. If that slack would overflow, request exactly what the
     * caller needs. */
    size_t slack = needed / 8;
    if (slack < 256) {
      slack = 256;
    }
    if (needed <= SIZE_MAX - slack) {
      new_cap = needed + slack;
    } else {
      new_cap = needed;
    }
  } else {
    /* Rejoin the power-of-two sequence after an off-sequence bulk growth. */
    while ((new_cap & (new_cap - 1)) != 0) {
      new_cap &= new_cap - 1;
    }
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

/* Expand all completed prefixes in one backward pass. The source spans are
 * disjoint: each original byte moves at most once, regardless of nesting.
 * Reserve before changing any bytes so a failed grow leaves scratch usable. */
static inline int titan_protobuf_buf_materialize_nested(
    titan_protobuf_buffer *buf, titan_protobuf_backpatch *patches) {
  if (patches->extra == 0) {
    return 1;
  }
  if (!titan_protobuf_buf_reserve(buf, patches->extra)) {
    return 0;
  }
  size_t read_end = buf->length;
  size_t shift = patches->extra;
  for (unsigned int i = patches->count; i > 0; i--) {
    titan_protobuf_patch *patch = &patches->entries[i - 1];
    if (patch->vlen <= 1) {
      continue;
    }
    size_t start = patch->mark + 1;
    size_t moved = read_end - start;
    if (moved != 0) {
      memmove(buf->data + start + shift, buf->data + start, moved);
    }
    shift -= patch->vlen - 1;
    uint32_t remaining = patch->payload_len;
    uint8_t *out = buf->data + patch->mark + shift;
    while (remaining >= 128) {
      *out++ = (uint8_t)((remaining & 127) | 128);
      remaining >>= 7;
    }
    *out = (uint8_t)remaining;
    read_end = patch->mark;
  }
  buf->length += patches->extra;
  /* Earlier siblings can precede a still-open message. Its opening debt is
   * exactly the displacement of its mark; callers' old numeric marks are
   * not reused for these tracked frames after entering eager fallback. */
  for (unsigned int i = 0; i < patches->count; i++) {
    titan_protobuf_patch *patch = &patches->entries[i];
    if (patch->vlen == 0) {
      patch->mark += patch->extra_before;
      patch->extra_before = 0;
    }
  }
  patches->extra = 0;
  return 1;
}

static inline int64_t titan_protobuf_buf_begin_nested(
    titan_protobuf_buffer *buf, titan_protobuf_backpatch *patches,
    int64_t key_bits) {
  if (patches->depth == 0) {
    patches->count = 0;
    patches->extra = 0;
    patches->fallback_depth = 0;
    patches->active = TITAN_PROTOBUF_BACKPATCH_LIMIT;
  } else if (patches->fallback_depth == 0 &&
             patches->count == TITAN_PROTOBUF_BACKPATCH_LIMIT) {
    if (!titan_protobuf_buf_materialize_nested(buf, patches)) {
      return -1;
    }
    patches->fallback_depth = patches->depth;
  }
  if (!titan_protobuf_buf_write_varint(buf, key_bits)) {
    return -1;
  }
  if (!titan_protobuf_buf_reserve(buf, 1)) {
    return -1;
  }
  size_t mark = buf->length;
  buf->data[mark] = 0;
  buf->length = mark + 1;
  if (patches->fallback_depth == 0) {
    titan_protobuf_patch *patch = &patches->entries[patches->count];
    patch->mark = mark;
    patch->payload_len = 0;
    patch->extra_before = (uint16_t)patches->extra;
    patch->parent = (uint8_t)patches->active;
    patch->vlen = 0;
    patches->active = patches->count++;
  }
  patches->depth++;
  return (int64_t)mark;
}

static inline int titan_protobuf_buf_end_nested_eager(
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

static inline int titan_protobuf_buf_end_nested(
    titan_protobuf_buffer *buf, titan_protobuf_backpatch *patches,
    int64_t mark_idx) {
  if (patches->fallback_depth != 0) {
    /* fallback_depth is the depth of the innermost still-open pre-fallback
     * frame. A frame opened after the fallback always lies strictly inside it,
     * so the closing frame is tracked exactly when the current depth reaches
     * that boundary, and every tracked close lowers it. A shallower sibling
     * opened after the fallback therefore stays eager and its caller's mark,
     * not an earlier entry, is authoritative. */
    int tracked = patches->depth == patches->fallback_depth;
    titan_protobuf_patch *patch =
        tracked ? &patches->entries[patches->active] : NULL;
    int rc = titan_protobuf_buf_end_nested_eager(
        buf, patch != NULL ? (int64_t)patch->mark : mark_idx);
    if (rc > 0) {
      if (patch != NULL) {
        patches->active = patch->parent;
        patches->fallback_depth--;
      }
      patches->depth--;
    }
    return rc;
  }
  titan_protobuf_patch *patch = &patches->entries[patches->active];
  size_t physical_len = buf->length - (patch->mark + 1);
  size_t descendant_extra = patches->extra - patch->extra_before;
  if (physical_len > 2147483647ULL ||
      descendant_extra > 2147483647ULL - physical_len) {
    return -1;
  }
  size_t payload_len = physical_len + descendant_extra;
  uint8_t vlen = 1;
  for (size_t remaining = payload_len; remaining >= 128; remaining >>= 7) {
    vlen++;
  }
  size_t total_extra = patches->extra + vlen - 1;
  /* Do the only fallible operation before completing the outer frame. */
  if (patches->depth == 1 &&
      !titan_protobuf_buf_reserve(buf, total_extra)) {
    return 0;
  }
  patch->payload_len = (uint32_t)payload_len;
  patch->vlen = vlen;
  if (vlen == 1) {
    buf->data[patch->mark] = (uint8_t)payload_len;
  }
  patches->extra = total_extra;
  patches->active = patch->parent;
  patches->depth--;
  if (patches->depth == 0) {
    return titan_protobuf_buf_materialize_nested(buf, patches);
  }
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

