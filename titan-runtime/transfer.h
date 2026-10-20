#ifndef TITAN_TRANSFER_H
#define TITAN_TRANSFER_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lobject.h"
#include "lstring.h"
#include "ltable.h"
#include "titan/ffi.h"

/* Immutable code addresses and compile-time metadata only. Titan's private
 * foreign helpers reserve callback stack space; generated code uses the
 * calling state's rooted module and immediate captures. */
#define TITAN_TRANSFER_MANIFEST_SYMBOL "__titan_transfer_manifest"

typedef struct TitanTransferEntry {
    void *native;
    lua_CFunction strict;
    unsigned capture_count;
    void (*project)(lua_State *, CClosure *);
    void (*restore)(lua_State *, Udata *, int);
} TitanTransferEntry;

typedef struct TitanTransferModule {
    const char *name;
    unsigned entry_count;
    const TitanTransferEntry *entries;
} TitanTransferModule;

/* ------------------------------------------------------------------------
 * Protocol Buffers wire buffer. titan.protobuf owns the wire format; this SDK
 * header carries the writer primitives because compiler-generated nominal
 * codecs in every module append through them.
 * ------------------------------------------------------------------------ */

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

/* ------------------------------------------------------------------------
 * Compiler-generated nominal codecs.
 *
 * A generated codec replicates titan.protobuf's reflective record/union codec
 * exactly on the inputs it accepts and otherwise declines with status 0. It
 * never raises a codec error, calls a hook or resource codec, loads a module,
 * or enters Lua: an encoder only appends bytes, a decoder only allocates fresh
 * nominals and strings. The caller therefore restores its buffer or stack and
 * reruns the complete root reflectively, which raises the exact reflective
 * errors in the exact reflective order. `resources` is titan.protobuf's
 * registered resource-codec table keyed by canonical metatable; a registered
 * capability takes precedence over every generated codec.
 * ------------------------------------------------------------------------ */

#define TITAN_CODEC_DEPTH_LIMIT 128

/* The current encode path, one automatic link per open record or union. */
typedef struct TitanCodecPath {
    const Udata *object;
    const struct TitanCodecPath *parent;
} TitanCodecPath;

typedef int (*TitanCodecEncode)(lua_State *L, const TValue *resources,
    titan_protobuf_buffer *buf, Udata *object, const TitanCodecPath *path,
    int depth);

/* On success pushes exactly one fresh nominal; on decline leaves the stack. */
typedef int (*TitanCodecDecode)(lua_State *L, const TValue *resources,
    Udata *module, const uint8_t *data, size_t length, int depth);

/* One immutable entry per generated record or union, emitted beside the
 * module manifest. The declaring module's initializer binds its canonical
 * metatable to the entry address under TITAN_MT_CODEC, beside
 * TITAN_MT_PROJECT/TITAN_MT_CONSTRUCT. */
typedef struct TitanTransferCodec {
    const char *name;
    int is_union;
    TitanCodecEncode encode;
    TitanCodecDecode decode;
} TitanTransferCodec;

/* Resolve a canonical nominal metatable to its bound generated codec. Raw
 * reads only: no allocation, metamethod, or error. NULL selects reflection:
 * no generated codec, or a registered resource capability, which precedes
 * every structural encoding exactly as on the reflective path. */
static inline const TitanTransferCodec *titan_codec_for_metatable(
    lua_State *L, const TValue *resources, Table *metatable) {
  TValue key;
  TValue slot;
  if (metatable == NULL) {
    return NULL;
  }
  setpvalue(&key, TITAN_MT_CODEC);
  if (tagisempty(luaH_get(metatable, &key, &slot)) || !ttislightuserdata(&slot)) {
    return NULL;
  }
  const TitanTransferCodec *codec = (const TitanTransferCodec *)pvalue(&slot);
  if (resources != NULL && ttistable(resources)) {
    sethvalue(L, &key, metatable);
    if (!tagisempty(luaH_get(hvalue(resources), &key, &slot))) {
      return NULL;
    }
  }
  return codec;
}

/* The declaring module of a canonical nominal metatable, which generated
 * decoders need for their own metatable and nested nominal slots. */
static inline Udata *titan_codec_module(Table *metatable) {
  TValue key;
  TValue slot;
  setpvalue(&key, TITAN_MT_MOD);
  if (tagisempty(luaH_get(metatable, &key, &slot)) || !ttisfulluserdata(&slot)) {
    return NULL;
  }
  return uvalue(&slot);
}

/* The codec for a field statically typed as the nominal `name`. The name and
 * kind recheck keeps a mistyped value on the reflective path. */
static inline const TitanTransferCodec *titan_codec_for_field(
    lua_State *L, const TValue *resources, const TValue *field,
    const char *name, int is_union) {
  if (!ttisfulluserdata(field)) {
    return NULL;
  }
  const TitanTransferCodec *codec = titan_codec_for_metatable(
      L, resources, uvalue(field)->metatable);
  if (codec == NULL || codec->is_union != is_union ||
      strcmp(codec->name, name) != 0) {
    return NULL;
  }
  return codec;
}

static inline const TitanTransferCodec *titan_codec_for_value(
    lua_State *L, const TValue *resources, const TValue *candidate) {
  if (!ttisfulluserdata(candidate)) {
    return NULL;
  }
  return titan_codec_for_metatable(
      L, resources, uvalue(candidate)->metatable);
}

static inline int titan_codec_on_path(
    const TitanCodecPath *path, const Udata *object) {
  for (; path != NULL; path = path->parent) {
    if (path->object == object) {
      return 1;
    }
  }
  return 0;
}

static inline int64_t titan_codec_zigzag(lua_Integer number) {
  uint64_t bits = (uint64_t)number;
  return (int64_t)((bits << 1) ^ (number < 0 ? UINT64_MAX : 0));
}

static inline lua_Integer titan_codec_unzigzag(uint64_t bits) {
  return (lua_Integer)((bits >> 1) ^ (0 - (bits & 1)));
}

static inline int titan_codec_write_string(
    titan_protobuf_buffer *buf, int64_t key, const TValue *field) {
  if (!ttisstring(field)) {
    return 0;
  }
  TString *text = tsvalue(field);
  size_t length = tsslen(text);
  if (length > 2147483647u) {
    return 0;
  }
  return titan_protobuf_buf_write_bytes(buf, key, getstr(text), length);
}

/* Varint with the reflective reader's exact acceptance: at most ten bytes,
 * the tenth no larger than one. */
static inline int titan_codec_read_varint(const uint8_t *data, size_t length,
    size_t *position, uint64_t *out) {
  uint64_t bits = 0;
  size_t at = *position;
  for (unsigned index = 0; index < 10; index++) {
    if (at >= length) {
      return 0;
    }
    uint64_t byte = data[at++];
    if (index == 9 && byte > 1) {
      return 0;
    }
    bits |= (byte & 127) << (index * 7);
    if (byte < 128) {
      *position = at;
      *out = bits;
      return 1;
    }
  }
  return 0;
}

/* 1 consumes the next key when it equals `key`; 0 leaves another field (or
 * the end) for later declared fields; -1 reports a malformed key. */
static inline int titan_codec_take_key(const uint8_t *data, size_t length,
    size_t *position, uint64_t key) {
  if (*position >= length) {
    return 0;
  }
  size_t at = *position;
  uint64_t bits;
  if (!titan_codec_read_varint(data, length, &at, &bits)) {
    return -1;
  }
  if (bits != key) {
    return 0;
  }
  *position = at;
  return 1;
}

static inline int titan_codec_take_slice(const uint8_t *data, size_t length,
    size_t *position, size_t *offset, size_t *count) {
  size_t at = *position;
  uint64_t bits;
  if (!titan_codec_read_varint(data, length, &at, &bits)) {
    return 0;
  }
  if (bits > 2147483647u || bits > (uint64_t)(length - at)) {
    return 0;
  }
  *offset = at;
  *count = (size_t)bits;
  *position = at + (size_t)bits;
  return 1;
}

static inline int titan_codec_take_fixed64(const uint8_t *data, size_t length,
    size_t *position, double *out) {
  if (length - *position < 8) {
    return 0;
  }
  *out = titan_protobuf_read_double(data, *position);
  *position += 8;
  return 1;
}

/* One nested nominal field: its key, a length prefix, and the nested codec's
 * fields, exactly as Encoder:field writes a nested message. */
static inline int titan_codec_encode_nested(lua_State *L,
    const TValue *resources, titan_protobuf_buffer *buf, const TValue *field,
    const char *name, int is_union, int64_t key, const TitanCodecPath *path,
    int depth) {
  const TitanTransferCodec *codec =
      titan_codec_for_field(L, resources, field, name, is_union);
  if (codec == NULL) {
    return 0;
  }
  int64_t mark = titan_protobuf_buf_begin_nested(buf, key);
  if (mark < 0) {
    return 0;
  }
  if (!codec->encode(L, resources, buf, uvalue(field), path, depth)) {
    return 0;
  }
  return titan_protobuf_buf_end_nested(buf, mark) > 0;
}

/* Decode one nominal from the exact canonical metatable of its declared type.
 * Success pushes it; decline leaves the stack unchanged. */
static inline int titan_codec_decode_nested(lua_State *L,
    const TValue *resources, const TValue *metatable, const uint8_t *data,
    size_t length, int depth) {
  if (!ttistable(metatable)) {
    return 0;
  }
  Table *nominal = hvalue(metatable);
  const TitanTransferCodec *codec =
      titan_codec_for_metatable(L, resources, nominal);
  if (codec == NULL) {
    return 0;
  }
  Udata *module = titan_codec_module(nominal);
  if (module == NULL) {
    return 0;
  }
  return codec->decode(L, resources, module, data, length, depth);
}

/* Root encode. `codec` comes from titan_codec_for_value; rechecking the
 * candidate's binding keeps a stale or mismatched handle from reading another
 * nominal's layout. Decline restores the append boundary. */
static inline int titan_codec_encode_root(lua_State *L, const TValue *resources,
    titan_protobuf_buffer *buf, const TitanTransferCodec *codec,
    const TValue *candidate) {
  if (codec == NULL || titan_codec_for_value(L, resources, candidate) != codec) {
    return 0;
  }
  size_t start = buf->length;
  if (codec->encode(L, resources, buf, uvalue(candidate), NULL, 1) &&
      buf->length - start <= 2147483647u) {
    return 1;
  }
  buf->length = start;
  return 0;
}

/* Root decode for a canonical nominal metatable. Success leaves exactly one
 * fresh nominal above the entry top; decline leaves the stack unchanged. */
static inline int titan_codec_decode_root(lua_State *L, const TValue *resources,
    const TValue *metatable, const void *data, size_t length) {
  if (length > 2147483647u) {
    return 0;
  }
  return titan_codec_decode_nested(
      L, resources, metatable, (const uint8_t *)data, length, 1);
}

#endif
