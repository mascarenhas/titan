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
 * A generated codec is titan.protobuf's reflective record/union codec
 * specialized to one nominal's storage plan. It writes and accepts exactly the
 * reflective wire and raises the exact reflective error string at the exact
 * reflective point; it never declines or reruns. A field it does not encode
 * natively (Arrays, foreign values, hooked or private nominals, registered
 * resource capabilities, merged or otherwise unusual wire) is handed to
 * titan.protobuf's reflective field codec through one fixed Titan entry, and
 * the reflective codec calls back into the generated codec of any nominal
 * that has one. Both sides share the root's buffer, cycle path, depth, packet
 * context, and one reflective Encoder per root.
 * ------------------------------------------------------------------------ */

#define TITAN_CODEC_DEPTH_LIMIT 128

/* Reflective handoff operations (TitanCodecHandoff.op). */
#define TITAN_CODEC_ENCODE_FIELD 1
#define TITAN_CODEC_ENCODE_RESOURCE 2
#define TITAN_CODEC_DECODE_FIELD 3
#define TITAN_CODEC_DECODE_RESOURCE 4
#define TITAN_CODEC_DECODE_NOMINAL 5

/* The open generated records and unions of the current root, one automatic
 * link per frame. Reflective frames keep their own active Map instead. */
typedef struct TitanCodecPath {
    const void *object;
    const struct TitanCodecPath *parent;
} TitanCodecPath;

/* Root-scoped collaboration state on the C stack. Its TValues copy values
 * that the calling Titan frames keep rooted for the whole operation:
 * titan.protobuf's resource-codec table and handoff entry, the packet
 * context, the enclosing reflective Encoder's active Map (or nil), and the
 * string owning the decoded bytes (or nil). An encode state also owns one
 * Lua stack slot (`encoder`, a savestack offset; -1 when decoding) holding
 * the reflective Encoder that every field handoff of this state reuses: the
 * enclosing Encoder when a reflective frame entered the generated codec, or
 * nil until the first handoff of a generated root creates one. */
typedef struct TitanCodecState {
    TValue resources;
    TValue context;
    TValue active;
    TValue handoff;
    TValue holder;
    ptrdiff_t encoder;
    int lazy_context;
    titan_protobuf_buffer *buf;
} TitanCodecState;

/* Encode appends one record or union message body at `depth`. Decode parses
 * `data`, leaves exactly one fresh nominal on the stack, and raises the exact
 * reflective error for malformed or ineligible input. */
typedef void (*TitanCodecEncode)(lua_State *L, TitanCodecState *state,
    Udata *object, const TitanCodecPath *path, int depth);
typedef void (*TitanCodecDecode)(lua_State *L, TitanCodecState *state,
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

/* The latest occurrence of one declared field and its occurrence count. */
typedef struct TitanCodecField {
    uint32_t count;
    uint32_t wire;
    uint64_t bits;
    size_t offset;
    size_t length;
} TitanCodecField;

/* One reflective field operation. `owner` names the nominal whose hydrated
 * descriptor supplies field `index` of `variant` (0 for a record), or the
 * expected resource/decoded nominal. `data`/`length` are the message holding
 * the field (decode) or the payload slice (resource decode). A field decode
 * also carries the field's directory entry (`field_*`, with the reflective
 * reader's signed bits): at most one occurrence decodes from that entry
 * alone, and only a repeated field reparses `data`. `keep` is the savestack
 * offset of the Lua stack slot holding the reusable reflective object (the
 * state's Encoder, or the decoding frame's one-field Message), or -1. */
typedef struct TitanCodecHandoff {
    int op;
    int lazy_context;
    const char *owner;
    int variant;
    int index;
    int number;
    int depth;
    titan_protobuf_buffer *buf;
    const TitanCodecPath *path;
    const uint8_t *data;
    size_t length;
    uint32_t field_count;
    uint32_t field_wire;
    int64_t field_bits;
    size_t field_offset;
    size_t field_length;
    ptrdiff_t keep;
} TitanCodecHandoff;

/* The exact value of Titan `raise "..."`: the string itself, no location. */
static inline void titan_codec_raise(lua_State *L, const char *message) {
  lua_checkstack(L, 1);
  lua_pushstring(L, message);
  lua_error(L);
}

static inline void titan_codec_depth(lua_State *L, int depth) {
  if (depth > TITAN_CODEC_DEPTH_LIMIT) {
    titan_codec_raise(L, "protobuf: nesting exceeds 128 levels");
  }
}

static inline void titan_codec_reserve(lua_State *L, int slots) {
  if (!lua_checkstack(L, slots)) {
    titan_codec_raise(L, "protobuf: cannot reserve Lua stack");
  }
}

/* Registered resource capabilities precede every structural encoding. */
static inline int titan_codec_has_resource(
    lua_State *L, const TValue *resources, Table *metatable) {
  TValue key;
  TValue slot;
  if (metatable == NULL || !ttistable(resources)) {
    return 0;
  }
  sethvalue(L, &key, metatable);
  return !tagisempty(luaH_get(hvalue(resources), &key, &slot));
}

/* Resolve a canonical nominal metatable to its bound generated codec. Raw
 * reads only: no allocation, metamethod, or error. NULL selects reflection:
 * no generated codec, or a registered resource capability. */
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
  if (titan_codec_has_resource(L, resources, metatable)) {
    return NULL;
  }
  return (const TitanTransferCodec *)pvalue(&slot);
}

/* `name` NULL accepts any nominal; `kind` -1 any, 0 record, 1 union. */
static inline const TitanTransferCodec *titan_codec_match(
    const TitanTransferCodec *codec, const char *name, int kind) {
  if (codec == NULL || (kind >= 0 && codec->is_union != kind) ||
      (name != NULL && strcmp(codec->name, name) != 0)) {
    return NULL;
  }
  return codec;
}

static inline const TitanTransferCodec *titan_codec_find(lua_State *L,
    TValue resources, TValue candidate, const char *name, int kind) {
  if (!ttisfulluserdata(&candidate)) {
    return NULL;
  }
  return titan_codec_match(titan_codec_for_metatable(
      L, &resources, uvalue(&candidate)->metatable), name, kind);
}

static inline const TitanTransferCodec *titan_codec_find_metatable(lua_State *L,
    TValue resources, TValue metatable, const char *name, int kind) {
  if (!ttistable(&metatable)) {
    return NULL;
  }
  return titan_codec_match(titan_codec_for_metatable(
      L, &resources, hvalue(&metatable)), name, kind);
}

/* The declaring module of a canonical nominal metatable, which generated
 * decoders need for their own metatable and nested nominal slots. */
static inline Udata *titan_codec_module(Table *metatable) {
  TValue key;
  TValue slot;
  if (metatable == NULL) {
    return NULL;
  }
  setpvalue(&key, TITAN_MT_MOD);
  if (tagisempty(luaH_get(metatable, &key, &slot)) || !ttisfulluserdata(&slot)) {
    return NULL;
  }
  return uvalue(&slot);
}

static inline int titan_codec_on_path(
    const TitanCodecPath *path, const void *object) {
  for (; path != NULL; path = path->parent) {
    if (path->object == object) {
      return 1;
    }
  }
  return 0;
}

/* Reflective Encoder:enter consults the generated frames of its root too. */
static inline int titan_codec_path_has(
    const TitanCodecPath *path, TValue candidate) {
  if (!iscollectable(&candidate)) {
    return 0;
  }
  return titan_codec_on_path(path, gcvalue(&candidate));
}

/* Encoder:enter for a generated frame: generated and reflective ancestors. */
static inline void titan_codec_enter(lua_State *L, const TitanCodecState *state,
    const TitanCodecPath *path, Udata *object) {
  if (titan_codec_on_path(path, obj2gco(object))) {
    titan_codec_raise(L, "protobuf: cyclic object graph");
  }
  if (ttistable(&state->active)) {
    TValue key;
    TValue slot;
    setuvalue(L, &key, object);
    if (!tagisempty(luaH_get(hvalue(&state->active), &key, &slot)) &&
        !l_isfalse(&slot)) {
      titan_codec_raise(L, "protobuf: cyclic object graph");
    }
  }
}

static inline int64_t titan_codec_zigzag(lua_Integer number) {
  uint64_t bits = (uint64_t)number;
  return (int64_t)((bits << 1) ^ (number < 0 ? UINT64_MAX : 0));
}

static inline lua_Integer titan_codec_unzigzag(uint64_t bits) {
  return (lua_Integer)((bits >> 1) ^ (0 - (bits & 1)));
}

static inline void titan_codec_put_varint(lua_State *L,
    titan_protobuf_buffer *buf, int64_t key, int64_t bits) {
  if (!titan_protobuf_buf_write_varint(buf, key) ||
      !titan_protobuf_buf_write_varint(buf, bits)) {
    titan_codec_raise(L, "protobuf: out of memory");
  }
}

static inline void titan_codec_put_double(lua_State *L,
    titan_protobuf_buffer *buf, int64_t key, lua_Number number) {
  if (!titan_protobuf_buf_write_double(buf, key, number)) {
    titan_codec_raise(L, "protobuf: out of memory");
  }
}

static inline void titan_codec_put_string(lua_State *L,
    titan_protobuf_buffer *buf, int64_t key, const TValue *field) {
  TString *text = tsvalue(field);
  size_t length = tsslen(text);
  if (length > 2147483647u) {
    titan_codec_raise(L, "protobuf: message exceeds 2 GiB");
  }
  if (!titan_protobuf_buf_write_bytes(buf, key, getstr(text), length)) {
    titan_codec_raise(L, "protobuf: out of memory");
  }
}

static inline int64_t titan_codec_begin(lua_State *L, TitanCodecState *state,
    int64_t key) {
  int64_t mark = titan_protobuf_buf_begin_nested(state->buf, key);
  if (mark < 0) {
    titan_codec_raise(L, "protobuf: out of memory");
  }
  return mark;
}

static inline void titan_codec_end(lua_State *L, TitanCodecState *state,
    int64_t mark) {
  int rc = titan_protobuf_buf_end_nested(state->buf, mark);
  if (rc == 0) {
    titan_codec_raise(L, "protobuf: out of memory");
  }
  if (rc < 0) {
    titan_codec_raise(L, "protobuf: message exceeds 2 GiB");
  }
}

/* titan.protobuf's handoff entry is an ordinary Titan function of exactly
 * this type; titan_codec_call invokes its native entry directly, as a
 * first-class Titan call does, without a Lua call frame. The function-type
 * tag in the closure's upvalue 1 must spell TITAN_CODEC_HANDOFF_TYPE, so a
 * handoff whose Titan signature no longer matches TitanCodecHandoffEntry
 * raises instead of calling through a mismatched pointer.
 * spec/coder/nominal_codec_spec.lua pins both spellings to the compiler's own
 * function-type identity and native-entry signature. */
#define TITAN_CODEC_HANDOFF_TYPE \
    "Function({Value(),Value(),Value(),Value()},{Value()},false,nil,nil)"
typedef TValue (*TitanCodecHandoffEntry)(lua_State *L, Udata *_mod,
    CClosure *_fn, TValue, TValue, TValue, TValue);

/* The reusable object of a request, or nil. */
static inline TValue titan_codec_kept(lua_State *L,
    const TitanCodecHandoff *request) {
  TValue kept;
  setnilvalue(&kept);
  if (request->keep >= 0) {
    setobj(L, &kept, s2v(restorestack(L, request->keep)));
  }
  return kept;
}

/* titan.protobuf stores the reusable object it created for this request. */
static inline void titan_codec_keep(lua_State *L, TitanCodecHandoff *request,
    TValue kept) {
  if (request->keep >= 0) {
    setobj2s(L, restorestack(L, request->keep), &kept);
  }
}

static inline TValue titan_codec_call(lua_State *L, TitanCodecState *state,
    TitanCodecHandoff *request, const TValue *item) {
  TValue handle;
  CClosure *closure = ttisCclosure(&state->handoff)
      ? clCvalue(&state->handoff) : NULL;
  if (closure == NULL || closure->nupvalues < 5 ||
      !ttisfulluserdata(&closure->upvalue[0]) ||
      !ttislightuserdata(&closure->upvalue[1]) ||
      !ttislightuserdata(&closure->upvalue[2]) ||
      !ttislightuserdata(&closure->upvalue[3]) ||
      pvalue(&closure->upvalue[3]) != TITAN_BRAND ||
      strcmp((const char *)pvalue(&closure->upvalue[1]),
          TITAN_CODEC_HANDOFF_TYPE) != 0) {
    titan_codec_raise(L, "protobuf: invalid codec handoff");
  }
  request->lazy_context = state->lazy_context;
  setpvalue(&handle, request);
  TitanCodecHandoffEntry entry = titan_cast_func(
      TitanCodecHandoffEntry, pvalue(&closure->upvalue[2]));
  return entry(L, uvalue(&closure->upvalue[0]), closure, handle, *item,
      state->context, titan_codec_kept(L, request));
}

/* `item` is the field value (rooted by its owner or on the stack). */
static inline void titan_codec_encode_handoff(lua_State *L,
    TitanCodecState *state, int op, const char *owner, int variant, int index,
    int number, const TitanCodecPath *path, int depth, const TValue *item) {
  TitanCodecHandoff request;
  memset(&request, 0, sizeof(request));
  request.op = op;
  request.owner = owner;
  request.variant = variant;
  request.index = index;
  request.number = number;
  request.depth = depth;
  request.buf = state->buf;
  request.path = path;
  request.keep = op == TITAN_CODEC_ENCODE_FIELD ? state->encoder : -1;
  (void)titan_codec_call(L, state, &request, item);
}

/* Encoder:field for a statically typed record or union field. A registered
 * resource capability, a generated codec of exactly that nominal, and
 * otherwise the reflective field encoder, in the reflective order. */
static inline void titan_codec_put_nominal(lua_State *L, TitanCodecState *state,
    const TValue *field, const char *name, int is_union, int number,
    const TitanCodecPath *path, int depth, const char *owner, int variant,
    int index) {
  if (ttisfulluserdata(field)) {
    Table *metatable = uvalue(field)->metatable;
    if (!is_union && titan_codec_has_resource(L, &state->resources, metatable)) {
      titan_codec_encode_handoff(L, state, TITAN_CODEC_ENCODE_RESOURCE, name,
          0, 0, number, path, depth, field);
      return;
    }
    const TitanTransferCodec *codec = titan_codec_match(
        titan_codec_for_metatable(L, &state->resources, metatable), name,
        is_union);
    if (codec != NULL) {
      int64_t mark = titan_codec_begin(L, state, (int64_t)number * 8 + 2);
      codec->encode(L, state, uvalue(field), path, depth);
      titan_codec_end(L, state, mark);
      return;
    }
  }
  titan_codec_encode_handoff(L, state, TITAN_CODEC_ENCODE_FIELD, owner,
      variant, index, number, path, depth, field);
}

static inline void titan_codec_state(TitanCodecState *state, TValue resources,
    TValue context, TValue active, TValue handoff, TValue holder,
    int lazy_context, titan_protobuf_buffer *buf, ptrdiff_t encoder) {
  state->resources = resources;
  state->context = context;
  state->active = active;
  state->handoff = handoff;
  state->holder = holder;
  state->encoder = encoder;
  state->lazy_context = lazy_context;
  state->buf = buf;
}

/* Push the Encoder slot of an encode state (balanced by the caller). */
static inline ptrdiff_t titan_codec_encoder_slot(lua_State *L,
    const TValue *encoder) {
  titan_codec_reserve(L, 1);
  setobj2s(L, L->top.p, encoder);
  L->top.p++;
  return savestack(L, L->top.p - 1);
}

/* A protobuf or packet root. Without a carried context, a handoff resolves
 * the current execution's encode scope exactly as the reflective root does.
 * The Encoder slot stays rooted until the root returns or raises. */
static inline void titan_codec_encode_root(lua_State *L, TValue resources,
    TValue context, int lazy_context, TValue handoff,
    titan_protobuf_buffer *buf,
    const TitanTransferCodec *codec, TValue candidate) {
  TitanCodecState state;
  TValue none;
  setnilvalue(&none);
  ptrdiff_t encoder = titan_codec_encoder_slot(L, &none);
  titan_codec_state(&state, resources, context, none, handoff, none,
      lazy_context, buf, encoder);
  codec->encode(L, &state, uvalue(&candidate), NULL, 1);
  L->top.p--;
}

/* The reflective Encoder's structural branch for a nominal with a codec:
 * every handoff below reuses that Encoder and consults its active Map. */
static inline void titan_codec_encode_field(lua_State *L, TValue resources,
    TValue context, TValue active, TValue encoder, TValue handoff,
    titan_protobuf_buffer *buf, const TitanCodecPath *path,
    const TitanTransferCodec *codec, TValue candidate, lua_Integer number,
    lua_Integer depth) {
  TitanCodecState state;
  TValue none;
  setnilvalue(&none);
  ptrdiff_t slot = titan_codec_encoder_slot(L, &encoder);
  titan_codec_state(&state, resources, context, active, handoff, none, 0, buf,
      slot);
  int64_t mark = titan_codec_begin(L, &state, (int64_t)number * 8 + 2);
  codec->encode(L, &state, uvalue(&candidate), path, (int)depth);
  titan_codec_end(L, &state, mark);
  L->top.p--;
}

/* WireReader, with the exact reflective acceptance and error strings. */
static inline uint64_t titan_codec_varint(lua_State *L, const uint8_t *data,
    size_t limit, size_t *position) {
  uint64_t bits = 0;
  for (unsigned index = 0; index < 10; index++) {
    if (*position >= limit) {
      titan_codec_raise(L, "protobuf: truncated varint");
    }
    uint64_t byte = data[(*position)++];
    if (index == 9 && byte > 1) {
      titan_codec_raise(L, "protobuf: varint overflow");
    }
    bits |= (byte & 127) << (index * 7);
    if (byte < 128) {
      return bits;
    }
  }
  titan_codec_raise(L, "protobuf: varint overflow");
  return 0;
}

static inline size_t titan_codec_take(lua_State *L, size_t limit,
    size_t *position, uint64_t count) {
  if (count > (uint64_t)(limit - *position)) {
    titan_codec_raise(L, "protobuf: truncated field");
  }
  size_t offset = *position;
  *position += (size_t)count;
  return offset;
}

static inline void titan_codec_key(lua_State *L, const uint8_t *data,
    size_t limit, size_t *position, uint32_t *number, uint32_t *wire) {
  uint64_t key = titan_codec_varint(L, data, limit, position);
  if (key > 4294967295u) {
    titan_codec_raise(L, "protobuf: invalid field key");
  }
  *number = (uint32_t)(key >> 3);
  *wire = (uint32_t)(key & 7);
  if (*number == 0) {
    titan_codec_raise(L, "protobuf: field number zero");
  }
}

static inline void titan_codec_field(lua_State *L, const uint8_t *data, size_t limit,
    size_t *position, uint32_t number, uint32_t wire, int depth,
    TitanCodecField *field) {
  field->bits = 0;
  field->offset = 0;
  field->length = 0;
  switch (wire) {
    case 0:
      field->bits = titan_codec_varint(L, data, limit, position);
      return;
    case 1:
      field->offset = titan_codec_take(L, limit, position, 8);
      field->length = 8;
      return;
    case 2: {
      uint64_t count = titan_codec_varint(L, data, limit, position);
      if (count > 2147483647u) {
        titan_codec_raise(L, "protobuf: invalid byte length");
      }
      field->offset = titan_codec_take(L, limit, position, count);
      field->length = (size_t)count;
      return;
    }
    case 5:
      field->offset = titan_codec_take(L, limit, position, 4);
      field->length = 4;
      return;
    case 3: {
      TitanCodecField nested;
      titan_codec_depth(L, depth);
      while (*position < limit) {
        uint32_t nested_number;
        uint32_t nested_wire;
        titan_codec_key(L, data, limit, position, &nested_number, &nested_wire);
        if (nested_wire == 4) {
          if (nested_number != number) {
            titan_codec_raise(L, "protobuf: mismatched end group");
          }
          return;
        }
        titan_codec_field(L, data, limit, position, nested_number, nested_wire,
            depth + 1, &nested);
      }
      titan_codec_raise(L, "protobuf: unterminated group");
      return;
    }
    default:
      titan_codec_raise(L, "protobuf: invalid wire type");
      return;
  }
}

/* protobuf field_ordinal: numbering skips 19000..19999. */
static inline uint32_t titan_codec_ordinal(uint32_t number) {
  if (number >= 20000) {
    return number - 1000;
  }
  if (number >= 19000) {
    return 0;
  }
  return number;
}

/* read_message_slice: validate the complete message before any field is
 * decoded, recording the latest occurrence of each declared ordinal. */
static inline void titan_codec_parse(lua_State *L, const uint8_t *data,
    size_t length, TitanCodecField *fields, uint32_t count) {
  size_t position = 0;
  memset(fields, 0, (count > 0 ? count : 1) * sizeof(TitanCodecField));
  while (position < length) {
    uint32_t number;
    uint32_t wire;
    TitanCodecField entry;
    titan_codec_key(L, data, length, &position, &number, &wire);
    titan_codec_field(L, data, length, &position, number, wire, 1, &entry);
    uint32_t ordinal = titan_codec_ordinal(number);
    if (ordinal >= 1 && ordinal <= count) {
      TitanCodecField *field = &fields[ordinal - 1];
      field->count++;
      field->wire = wire;
      field->bits = entry.bits;
      field->offset = entry.offset;
      field->length = entry.length;
    }
  }
}

/* Validate the complete union message while keeping only its one recognized
 * occurrence. Multiple, repeated, or non-message variants select reflection,
 * after all wire fields (including unknown ones) have been validated. */
static inline uint32_t titan_codec_select_union(lua_State *L,
    const uint8_t *data, size_t length, uint32_t count,
    TitanCodecField *selected_field) {
  size_t position = 0;
  uint32_t selected = 0;
  int multiple = 0;
  while (position < length) {
    uint32_t number;
    uint32_t wire;
    TitanCodecField entry;
    titan_codec_key(L, data, length, &position, &number, &wire);
    titan_codec_field(L, data, length, &position, number, wire, 1, &entry);
    uint32_t ordinal = titan_codec_ordinal(number);
    if (ordinal >= 1 && ordinal <= count) {
      if (selected != 0 || wire != 2) {
        multiple = 1;
      }
      selected = ordinal;
      selected_field->offset = entry.offset;
      selected_field->length = entry.length;
    }
  }
  return multiple ? 0 : selected;
}

static inline void titan_codec_need(lua_State *L, const TitanCodecField *field,
    int number) {
  if (field->count == 0) {
    lua_checkstack(L, 1);
    lua_pushfstring(L, "protobuf: missing required field %I",
        (LUAI_UACINT)number);
    lua_error(L);
  }
}

static inline void titan_codec_wire(lua_State *L, const TitanCodecField *field,
    uint32_t wire) {
  if (field->wire != wire) {
    titan_codec_raise(L, "protobuf: unexpected wire type");
  }
}

static inline int titan_codec_get_boolean(lua_State *L,
    const TitanCodecField *field) {
  titan_codec_wire(L, field, 0);
  if (field->bits > 1) {
    titan_codec_raise(L, "protobuf: invalid boolean");
  }
  return (int)field->bits;
}

static inline lua_Integer titan_codec_get_integer(lua_State *L,
    const TitanCodecField *field) {
  titan_codec_wire(L, field, 0);
  return titan_codec_unzigzag(field->bits);
}

static inline lua_Number titan_codec_get_float(lua_State *L,
    const TitanCodecField *field, const uint8_t *data) {
  titan_codec_wire(L, field, 1);
  return titan_protobuf_read_double(data, field->offset);
}

static inline TString *titan_codec_get_string(lua_State *L,
    const TitanCodecField *field, const uint8_t *data) {
  titan_codec_wire(L, field, 2);
  return luaS_newlstr(L, (const char *)data + field->offset, field->length);
}

/* Pushes the reflective result. The caller reserved its stack slot before
 * the call, so the returned value is rooted without another allocation. */
static inline void titan_codec_decode_handoff(lua_State *L,
    TitanCodecState *state, int op, const char *owner, int variant, int index,
    int number, const uint8_t *data, size_t length, int depth) {
  TitanCodecHandoff request;
  memset(&request, 0, sizeof(request));
  request.op = op;
  request.owner = owner;
  request.variant = variant;
  request.index = index;
  request.number = number;
  request.depth = depth;
  request.data = data;
  request.length = length;
  request.keep = -1;
  TValue result = titan_codec_call(L, state, &request, &state->holder);
  lua_pushtvalue(L, result);
}

/* decode_field for one field the generated decoder does not decode natively.
 * `field` is its directory entry in the message `data`/`length`; `scratch`
 * is the savestack offset of the frame's one-field Message slot. Pushes the
 * reflective result into a slot the caller reserved. */
static inline void titan_codec_decode_field(lua_State *L,
    TitanCodecState *state, const char *owner, int variant, int index,
    int number, const TitanCodecField *field, const uint8_t *data,
    size_t length, int depth, ptrdiff_t scratch) {
  TitanCodecHandoff request;
  memset(&request, 0, sizeof(request));
  request.op = TITAN_CODEC_DECODE_FIELD;
  request.owner = owner;
  request.variant = variant;
  request.index = index;
  request.number = number;
  request.depth = depth;
  request.data = data;
  request.length = length;
  request.field_count = field->count;
  request.field_wire = field->wire;
  memcpy(&request.field_bits, &field->bits, sizeof(request.field_bits));
  request.field_offset = field->offset;
  request.field_length = field->length;
  request.keep = scratch;
  TValue result = titan_codec_call(L, state, &request, &state->holder);
  lua_pushtvalue(L, result);
}

/* decode_field for a present record or union field after its missing check.
 * `metatable` is the declared type's canonical metatable in the decoding
 * module. `data`/`length` are the message holding the field. */
static inline void titan_codec_get_nominal(lua_State *L, TitanCodecState *state,
    const TValue *metatable, const char *name, int is_union,
    const TitanCodecField *field, int number, const uint8_t *data,
    size_t length, int depth, const char *owner, int variant, int index,
    ptrdiff_t scratch) {
  Table *nominal = ttistable(metatable) ? hvalue(metatable) : NULL;
  if (!is_union && titan_codec_has_resource(L, &state->resources, nominal)) {
    titan_codec_wire(L, field, 2);
    titan_codec_decode_handoff(L, state, TITAN_CODEC_DECODE_RESOURCE, name, 0,
        0, number, data + field->offset, field->length, depth);
    return;
  }
  if (field->count == 1) {
    const TitanTransferCodec *codec = titan_codec_match(
        titan_codec_for_metatable(L, &state->resources, nominal), name,
        is_union);
    Udata *module = codec != NULL ? titan_codec_module(nominal) : NULL;
    if (module != NULL) {
      titan_codec_wire(L, field, 2);
      codec->decode(L, state, module, data + field->offset, field->length,
          depth);
      return;
    }
  }
  titan_codec_decode_field(L, state, owner, variant, index, number, field,
      data, length, depth, scratch);
}

/* The module name of a nominal value's declaring module, from its canonical
 * metatable and the module's manifest; NULL for anything else. Raw reads. */
static inline const char *titan_codec_nominal_module(TValue candidate) {
  if (!ttisfulluserdata(&candidate)) {
    return NULL;
  }
  Udata *module = titan_codec_module(uvalue(&candidate)->metatable);
  if (module == NULL || module->len < sizeof(TitanModuleData)) {
    return NULL;
  }
  const TitanModuleData *data = (const TitanModuleData *)getudatamem(module);
  if (data->symbols == NULL) {
    return NULL;
  }
  const TitanTransferModule *manifest = (const TitanTransferModule *)
      data->symbols(TITAN_TRANSFER_MANIFEST_SYMBOL);
  return manifest != NULL ? manifest->name : NULL;
}

/* Encoder:field for a `value` field: nil is absent; booleans, integers,
 * floats, and strings are the arms 1-4 of one nested TitanValue message.
 * Every other dynamic value uses the reflective field encoder. */
static inline void titan_codec_put_value(lua_State *L, TitanCodecState *state,
    const TValue *field, int number, const TitanCodecPath *path, int depth,
    const char *owner, int variant, int index) {
  int64_t key = (int64_t)number * 8 + 2;
  int64_t mark;
  if (ttisnil(field)) {
    return;
  }
  if (ttisboolean(field)) {
    mark = titan_codec_begin(L, state, key);
    titan_codec_put_varint(L, state->buf, 8, ttistrue(field) ? 1 : 0);
    titan_codec_end(L, state, mark);
    return;
  }
  if (ttisinteger(field)) {
    mark = titan_codec_begin(L, state, key);
    titan_codec_put_varint(L, state->buf, 16, titan_codec_zigzag(ivalue(field)));
    titan_codec_end(L, state, mark);
    return;
  }
  if (ttisfloat(field)) {
    mark = titan_codec_begin(L, state, key);
    titan_codec_put_double(L, state->buf, 25, fltvalue(field));
    titan_codec_end(L, state, mark);
    return;
  }
  if (ttisstring(field)) {
    mark = titan_codec_begin(L, state, key);
    titan_codec_put_string(L, state->buf, 34, field);
    titan_codec_end(L, state, mark);
    return;
  }
  titan_codec_encode_handoff(L, state, TITAN_CODEC_ENCODE_FIELD, owner,
      variant, index, number, path, depth, field);
}

/* decode_field for a `value` field: absent is nil; one length-delimited
 * TitanValue holding at most one scalar arm decodes natively, with the
 * reflective arm checks. Everything else uses the reflective field decoder
 * through the frame's one-field Message (`scratch`). */
static inline void titan_codec_get_value(lua_State *L, TitanCodecState *state,
    const TitanCodecField *field, int number, const uint8_t *data,
    size_t length, int depth, const char *owner, int variant, int index,
    ptrdiff_t scratch) {
  if (field->count == 0) {
    lua_pushnil(L);
    return;
  }
  if (field->count == 1 && field->wire == 2) {
    TitanCodecField arms[6];
    const uint8_t *slice = data + field->offset;
    uint32_t total = 0;
    uint32_t only = 0;
    titan_codec_parse(L, slice, field->length, arms, 6);
    for (uint32_t arm = 1; arm <= 6; arm++) {
      if (arms[arm - 1].count != 0) {
        total += arms[arm - 1].count;
        only = arm;
      }
    }
    if (total == 0) {
      lua_pushnil(L);
      return;
    }
    if (total == 1 && only <= 4) {
      const TitanCodecField *selected = &arms[only - 1];
      switch (only) {
        case 1:
          lua_pushboolean(L, titan_codec_get_boolean(L, selected));
          return;
        case 2:
          lua_pushinteger(L, titan_codec_get_integer(L, selected));
          return;
        case 3:
          lua_pushnumber(L, titan_codec_get_float(L, selected, slice));
          return;
        default: {
          TString *text = titan_codec_get_string(L, selected, slice);
          setsvalue2s(L, L->top.p, text);
          L->top.p++;
          return;
        }
      }
    }
  }
  titan_codec_decode_field(L, state, owner, variant, index, number, field,
      data, length, depth, scratch);
}

/* A protobuf root, a transfer packet, or the reflective decoder's
 * structural branch for a nominal with a codec. Leaves one value pushed. */
static inline void titan_codec_decode_nominal(lua_State *L, TValue resources,
    TValue context, TValue handoff, TValue holder,
    const TitanTransferCodec *codec, TValue metatable, const void *data,
    size_t length, lua_Integer depth) {
  TitanCodecState state;
  TValue none;
  setnilvalue(&none);
  titan_codec_state(&state, resources, context, none, handoff, holder, 0, NULL,
      -1);
  Udata *module = ttistable(&metatable)
      ? titan_codec_module(hvalue(&metatable)) : NULL;
  if (module == NULL) {
    titan_codec_raise(L, "protobuf: invalid codec handoff");
  }
  codec->decode(L, &state, module, (const uint8_t *)data, length, (int)depth);
}

#endif
