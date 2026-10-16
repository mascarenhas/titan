#include <stdlib.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"
#include "lstate.h"
#include "titan.h"

#define TITAN_TRANSFER_MAX_DEPTH 128u

/* Every allocation is linked before any operation that can raise. The owner
 * published by the caller can therefore free a partly encoded graph after a
 * Lua longjmp, without a native unwind or a second Lua-state entry. */
typedef struct TransferAllocation {
    struct TransferAllocation *next;
    union { long double number; void *pointer; lua_Integer integer; } alignment;
    unsigned char data[];
} TransferAllocation;

typedef enum TransferKind {
    TRANSFER_NIL, TRANSFER_BOOLEAN, TRANSFER_INTEGER, TRANSFER_NUMBER,
    TRANSFER_STRING, TRANSFER_POINTER, TRANSFER_CFUNCTION, TRANSFER_NOMINAL,
    TRANSFER_CLOSURE, TRANSFER_BOX_REFERENCE, TRANSFER_LUA_STATE,
    TRANSFER_RECORD_PAYLOAD, TRANSFER_POLICY_WRAPPER
} TransferKind;

typedef struct TransferNode TransferNode;
typedef struct TransferCapture {
    TransferNode *value;
    unsigned box;
} TransferCapture;

struct TransferNode {
    TransferKind kind;
    union {
        int boolean;
        lua_Integer integer;
        lua_Number number;
        void *pointer;
        lua_CFunction function;
        struct { const char *bytes; size_t length; } string;
        struct {
            const char *name;
            size_t name_length;
            const char *bytes;
            size_t length;
            int is_union;
        } nominal;
        struct {
            const TitanTransferModule *module;
            const TitanTransferEntry *entry;
            TransferCapture *captures;
        } closure;
        struct {
            const TitanTransferModule *module;
            const char *name;
            size_t name_length;
            unsigned count;
            TransferNode **values;
        } payload;
        TransferNode *policy;
        unsigned box;
    } as;
};

/* Only these temporary records contain origin-state identities. They are
 * destroyed before publication of a completed graph, including their pointers
 * from the owning graph. The finished graph has no borrowed Lua heap data. */
typedef struct TransferBox {
    struct TransferBox *next;
    const Udata *identity;
    unsigned ordinal;
    int active;
} TransferBox;

struct TitanTransferGraph {
    TransferAllocation *allocations;
    TransferAllocation *scratch;
    TransferNode *root;
    unsigned box_count;
    int started;
    int policy_root;
};

typedef struct TransferActive {
    const struct TransferActive *previous;
    const void *identity;
} TransferActive;

typedef struct TransferEncoder {
    TitanTransferGraph *graph;
    TransferBox *boxes;
    const TransferActive *active;
    int box_roots;
} TransferEncoder;

static void transfer_free_allocations(TransferAllocation *allocation) {
    while (allocation != NULL) {
        TransferAllocation *next = allocation->next;
        free(allocation);
        allocation = next;
    }
}

TitanTransferGraph *titan_transfer_new(void) {
    return (TitanTransferGraph *)calloc(1, sizeof(TitanTransferGraph));
}

void titan_transfer_free(TitanTransferGraph *graph) {
    if (graph == NULL) return;
    transfer_free_allocations(graph->allocations);
    transfer_free_allocations(graph->scratch);
    free(graph);
}

static void *transfer_allocate(lua_State *L, TransferAllocation **list,
                               size_t size) {
    TransferAllocation *allocation;
    if (size > SIZE_MAX - sizeof(*allocation))
        luaL_error(L, "Titan closure transfer is too large");
    allocation = (TransferAllocation *)malloc(sizeof(*allocation) + size);
    if (allocation == NULL)
        luaL_error(L, "cannot allocate Titan closure transfer");
    allocation->next = *list;
    *list = allocation;
    memset(allocation->data, 0, size);
    return allocation->data;
}

static const char *transfer_copy(lua_State *L, TitanTransferGraph *graph,
                                 const char *bytes, size_t length) {
    char *copy = (char *)transfer_allocate(L, &graph->allocations,
                                         length == 0 ? 1 : length);
    if (length != 0) memcpy(copy, bytes, length);
    return copy;
}

static int transfer_branded(const TValue *value) {
    CClosure *closure;
    if (!ttisCclosure(value)) return 0;
    closure = clCvalue(value);
    return closure->nupvalues >= 5
        && ttisfulluserdata(&closure->upvalue[0])
        && ttislightuserdata(&closure->upvalue[1])
        && ttislightuserdata(&closure->upvalue[2])
        && ttislightuserdata(&closure->upvalue[3])
        && pvalue(&closure->upvalue[3]) == TITAN_BRAND
        && ttislcf(&closure->upvalue[closure->nupvalues - 1]);
}

int titan_transfer_is_closure(lua_State *L, int index) {
    TValue value;
    if (lua_type(L, index) != LUA_TFUNCTION) return 0;
    value = lua_totvalue(L, index);
    return transfer_branded(&value);
}

static void transfer_library(lua_State *L, const char *name) {
    int top = lua_gettop(L);
    lua_CFunction loader;
    luaL_checkstack(L, 4, "loading Titan transfer support");
    lua_pushliteral(L, LUA_PRELOAD_TABLE);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1))
        luaL_error(L, "Titan transfer has no native loader for '%s'", name);
    lua_pushstring(L, name);
    lua_rawget(L, -2);
    loader = lua_tocfunction(L, -1);
    if (loader == NULL || lua_getupvalue(L, -1, 1) != NULL)
        luaL_error(L, "Titan transfer has no native loader for '%s'", name);
    lua_settop(L, top);
    luaL_requiref(L, name, loader, 0);
}

static void transfer_protobuf_function(lua_State *L, const char *name) {
    int top = lua_gettop(L);
    transfer_library(L, "titan.protobuf");
    lua_getfield(L, -1, name);
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}

static void transfer_policy_function(lua_State *L, const char *name) {
    int top = lua_gettop(L);
    transfer_library(L, "titan.async");
    lua_getfield(L, -1, "TransferValue");
    lua_getfield(L, -1, name);
    if (!lua_isfunction(L, -1))
        luaL_error(L, "Titan transfer support has no TransferValue.%s", name);
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}

static int transfer_is_policy(lua_State *L, int index) {
    return luaL_testudata(L, index,
        "Titan union titan.async.TransferValue metatable") != NULL;
}

static void transfer_policy_to_value(lua_State *L, int index) {
    index = lua_absindex(L, index);
    luaL_checkstack(L, 2, "reconstructing a Titan transfer payload");
    lua_getfield(L, index, "to_value");
    if (!lua_isfunction(L, -1))
        luaL_error(L, "Titan transfer support has no TransferValue:to_value");
    lua_pushvalue(L, index);
    lua_call(L, 1, 1);
}

/* Keep the canonical module on the stack so callbacks have a destination-state
 * root even if an initializer or user hook performs a full collection. */
static Udata *transfer_module(lua_State *L, const TitanTransferModule *module,
                               int initialize) {
    Udata *canonical;
    const TitanModuleData *data;
    int top = lua_gettop(L);
    luaL_checkstack(L, 2, "resolving a Titan closure module");
    lua_pushfstring(L, "Titan module %s", module->name);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_isnil(L, -1) && initialize) {
        lua_pop(L, 1);
        canonical = module->init(L);
        if (lua_gettop(L) != top)
            luaL_error(L, "Titan closure module initializer changed the stack");
        lua_pushfstring(L, "Titan module %s", module->name);
        lua_rawget(L, LUA_REGISTRYINDEX);
        if (lua_type(L, -1) != LUA_TUSERDATA
            || uvalue(s2v(L->top.p - 1)) != canonical)
            luaL_error(L, "Titan closure module '%s' did not publish its state",
                       module->name);
    }
    if (lua_type(L, -1) != LUA_TUSERDATA)
        luaL_error(L, "Titan closure module '%s' has invalid module state",
                   module->name);
    canonical = uvalue(s2v(L->top.p - 1));
    if (canonical->len < sizeof(TitanModuleData))
        luaL_error(L, "Titan closure module '%s' has no native descriptor",
                   module->name);
    data = (const TitanModuleData *)getudatamem(canonical);
    if (data->symbols != module->symbols)
        luaL_error(L, "Titan closure module '%s' belongs to a different provider",
                   module->name);
    return canonical;
}

/* A packet names a nominal, not a module: folder modules and nested owners
 * make splitting a dotted name incorrect. Recover the already-published owner
 * and retain only its immutable module capability in the native graph. */
static const TitanTransferModule *transfer_record_module(lua_State *L,
                                                          int name) {
    int top = lua_gettop(L);
    Udata *owner;
    const TitanModuleData *data;
    const TitanTransferModule *module;
    name = lua_absindex(L, name);
    luaL_checkstack(L, 5, "resolving a custom transfer record");
    lua_pushliteral(L, TITAN_METATABLES_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1))
        luaL_error(L, "custom transfer record has no nominal registry");
    lua_pushvalue(L, name);
    lua_rawget(L, -2);
    if (!lua_istable(L, -1))
        luaL_error(L, "custom transfer record is not initialized in the origin state");
    lua_rawgetp(L, -1, TITAN_BRAND);
    if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) != TITAN_RECORD)
        luaL_error(L, "custom transfer name does not identify a record");
    lua_pop(L, 1);
    lua_rawgetp(L, -1, TITAN_MT_PUBLIC);
    if (!lua_toboolean(L, -1))
        luaL_error(L, "custom transfer requires a public record");
    lua_pop(L, 1);
    lua_rawgetp(L, -1, TITAN_MT_MOD);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        luaL_error(L, "custom transfer record has no module owner");
    owner = uvalue(s2v(L->top.p - 1));
    if (owner->len < sizeof(TitanModuleData))
        luaL_error(L, "custom transfer record has no native module descriptor");
    data = (const TitanModuleData *)getudatamem(owner);
    if (data->symbols == NULL)
        luaL_error(L, "custom transfer record has no native module descriptor");
    module = (const TitanTransferModule *)
        data->symbols(TITAN_TRANSFER_MANIFEST_SYMBOL);
    if (module == NULL || module->name == NULL || module->init == NULL
        || module->symbols != data->symbols)
        luaL_error(L, "custom transfer record has no module transfer capability");
    if (transfer_module(L, module, 0) != owner)
        luaL_error(L, "custom transfer record does not own its canonical module state");
    lua_settop(L, top);
    return module;
}

static const TitanTransferEntry *transfer_descriptor(lua_State *L,
    CClosure *closure, const TitanTransferModule **owner) {
    Udata *module_value = uvalue(&closure->upvalue[0]);
    const TitanModuleData *data;
    const TitanTransferModule *module;
    unsigned i;
    if (module_value->len < sizeof(TitanModuleData))
        luaL_error(L, "Titan closure has no module export descriptor");
    data = (const TitanModuleData *)getudatamem(module_value);
    if (data->symbols == NULL)
        luaL_error(L, "Titan closure has no module export descriptor");
    module = (const TitanTransferModule *)
        data->symbols(TITAN_TRANSFER_MANIFEST_SYMBOL);
    if (module == NULL || module->name == NULL || module->init == NULL
        || module->symbols != data->symbols
        || (module->entry_count != 0 && module->entries == NULL))
        luaL_error(L, "Titan closure module has no transfer manifest");
    if (transfer_module(L, module, 0) != module_value)
        luaL_error(L, "Titan closure does not own its canonical module state");
    lua_pop(L, 1);
    for (i = 0; i < module->entry_count; ++i) {
        const TitanTransferEntry *entry = &module->entries[i];
        if (entry->native != pvalue(&closure->upvalue[2])
            || entry->strict != fvalue(&closure->upvalue[closure->nupvalues - 1]))
            continue;
        if (entry->project == NULL || entry->restore_capture == NULL
            || entry->restore == NULL || entry->capture_count > 250
            || (entry->capture_count != 0 && entry->boxed == NULL))
            luaL_error(L, "Titan closure has an invalid transfer descriptor");
        if (entry->kind == TITAN_TRANSFER_SOURCE) {
            if (closure->nupvalues != entry->capture_count + 5
                || closure->f != entry->coercive)
                luaL_error(L, "Titan closure does not match its transfer entry");
        } else if (entry->kind == TITAN_TRANSFER_ADAPTER) {
            if (entry->capture_count != 1 || entry->boxed[0]
                || closure->nupvalues < 6)
                luaL_error(L, "Titan closure has an invalid adapter entry");
        } else luaL_error(L, "Titan closure has an unknown transfer entry kind");
        *owner = module;
        return entry;
    }
    luaL_error(L, "Titan closure entry is absent from its module manifest");
    return NULL;
}

static TransferNode *transfer_encode_value(lua_State *L, TransferEncoder *state,
                                           int index, unsigned depth);
static TransferNode *transfer_encode_policy(lua_State *L, TransferEncoder *state,
                                            int index, unsigned depth);

static void transfer_enter(lua_State *L, TransferEncoder *state,
                            TransferActive *active, const void *identity,
                            const char *what) {
    const TransferActive *cursor;
    for (cursor = state->active; cursor != NULL; cursor = cursor->previous)
        if (cursor->identity == identity)
            luaL_error(L, "cannot transfer a cyclic %s", what);
    active->previous = state->active;
    active->identity = identity;
    state->active = active;
}

static void transfer_encode_closure(lua_State *L, TransferEncoder *state,
    int index, unsigned depth, TransferNode *node) {
    TValue value = lua_totvalue(L, index);
    CClosure *closure = clCvalue(&value);
    const TransferActive *cursor;
    TransferActive active;
    const TitanTransferEntry *entry;
    unsigned i;
    for (cursor = state->active; cursor != NULL; cursor = cursor->previous)
        if (cursor->identity == closure)
            luaL_error(L, "cannot transfer a cyclic Titan closure capture");
    entry = transfer_descriptor(L, closure, &node->as.closure.module);
    node->as.closure.entry = entry;
    node->as.closure.captures = (TransferCapture *)transfer_allocate(L,
        &state->graph->allocations, entry->capture_count * sizeof(TransferCapture));
    active.previous = state->active;
    active.identity = closure;
    state->active = &active;
    for (i = 0; i < entry->capture_count; ++i) {
        TransferCapture *capture = &node->as.closure.captures[i];
        TransferBox *box = NULL;
        int top = lua_gettop(L);
        if (entry->boxed[i]) {
            const TValue *slot = &closure->upvalue[i + 4];
            Udata *identity;
            if (!ttisfulluserdata(slot))
                luaL_error(L, "Titan closure capture box is invalid");
            identity = uvalue(slot);
            for (box = state->boxes; box != NULL; box = box->next)
                if (box->identity == identity) break;
            if (box != NULL) {
                if (box->active)
                    luaL_error(L, "cannot transfer a cyclic Titan closure capture box");
                capture->value = (TransferNode *)transfer_allocate(L,
                    &state->graph->allocations, sizeof(TransferNode));
                capture->value->kind = TRANSFER_BOX_REFERENCE;
                capture->value->as.box = box->ordinal;
                continue;
            }
            box = (TransferBox *)transfer_allocate(L, &state->graph->scratch,
                                                   sizeof(TransferBox));
            box->identity = identity;
            box->ordinal = ++state->graph->box_count;
            box->active = 1;
            box->next = state->boxes;
            state->boxes = box;
            capture->box = box->ordinal;
            /* Reentrant collection can mutate source cells and detach a
             * previously visited closure. Keep every dedup identity alive
             * until traversal ends, even when its source path disappears.
             * The stack copy roots this box before table growth can collect. */
            lua_pushtvalue(L, *slot);
            lua_rawseti(L, state->box_roots, box->ordinal);
        }
        entry->project(L, closure, i);
        if (lua_gettop(L) != top + 1)
            luaL_error(L, "Titan closure capture projection changed the stack");
        capture->value = transfer_encode_value(L, state, top + 1, depth + 1);
        lua_settop(L, top);
        if (box != NULL) box->active = 0;
    }
    state->active = active.previous;
}

typedef void (*TransferPolicyReader)(lua_State *, Udata *, lua_Integer, TValue *);

static void transfer_policy_part(lua_State *L, TransferPolicyReader reader,
                                  Udata *owner, lua_Integer index) {
    TValue value;
    setnilvalue(&value);
    reader(L, owner, index, &value);
    lua_pushtvalue(L, value);
}

/* Policy nodes retain their declared variant. In particular, a Lua-state
 * address remains distinct from an arbitrary pointer, and custom payloads
 * contain policies rather than the semantic values those policies describe. */
static TransferNode *transfer_encode_policy(lua_State *L, TransferEncoder *state,
                                            int index, unsigned depth) {
    int top = lua_gettop(L);
    TransferNode *node;
    TransferPolicyReader reader;
    Udata *owner;
    lua_Integer tag;
    const char *bytes;
    size_t length;
    index = lua_absindex(L, index);
    if (depth > TITAN_TRANSFER_MAX_DEPTH)
        luaL_error(L, "Titan transfer exceeds its payload depth limit");
    luaL_checkstack(L, 6, "encoding a Titan transfer policy");
    if (!transfer_is_policy(L, index))
        luaL_error(L, "custom transfer payload requires TransferValue entries");
    /* Keep the owner rooted at index across every recursive conversion. */
    {
        TValue value = lua_totvalue(L, index);
        owner = uvalue(&value);
    }
    lua_getmetatable(L, index);
    lua_rawgetp(L, -1, TITAN_MT_PAYLOAD);
    reader = titan_cast_func(TransferPolicyReader, lua_touserdata(L, -1));
    if (reader == NULL)
        luaL_error(L, "TransferValue has no canonical payload reader");
    lua_settop(L, top);
    transfer_policy_part(L, reader, owner, 0);
    if (!lua_isinteger(L, -1))
        luaL_error(L, "TransferValue has an invalid variant tag");
    tag = lua_tointeger(L, -1);
    lua_pop(L, 1);
    node = (TransferNode *)transfer_allocate(L, &state->graph->allocations,
                                            sizeof(TransferNode));
    if (tag != 0) transfer_policy_part(L, reader, owner, 1);
    switch (tag) {
    case 0: node->kind = TRANSFER_NIL; break;
    case 1:
        node->kind = TRANSFER_BOOLEAN;
        luaL_checktype(L, -1, LUA_TBOOLEAN);
        node->as.boolean = lua_toboolean(L, -1);
        break;
    case 2:
        node->kind = TRANSFER_INTEGER;
        node->as.integer = luaL_checkinteger(L, -1);
        break;
    case 3:
        node->kind = TRANSFER_NUMBER;
        node->as.number = luaL_checknumber(L, -1);
        break;
    case 4:
        node->kind = TRANSFER_STRING;
        luaL_checktype(L, -1, LUA_TSTRING);
        bytes = lua_tolstring(L, -1, &length);
        node->as.string.bytes = transfer_copy(L, state->graph, bytes, length);
        node->as.string.length = length;
        break;
    case 5:
    case 7:
        node->kind = tag == 5 ? TRANSFER_LUA_STATE : TRANSFER_POINTER;
        luaL_checktype(L, -1, LUA_TLIGHTUSERDATA);
        node->as.pointer = lua_touserdata(L, -1);
        break;
    case 6:
        node->kind = TRANSFER_CFUNCTION;
        luaL_checktype(L, -1, LUA_TLIGHTUSERDATA);
        node->as.function = titan_cast_func(lua_CFunction,
                                           lua_touserdata(L, -1));
        if (node->as.function == NULL)
            luaL_error(L, "cannot transfer a NULL Lua C function");
        break;
    case 8:
    case 9:
        node->kind = TRANSFER_NOMINAL;
        node->as.nominal.is_union = tag == 9;
        luaL_checktype(L, -1, LUA_TSTRING);
        bytes = lua_tolstring(L, -1, &length);
        node->as.nominal.name = transfer_copy(L, state->graph, bytes, length);
        node->as.nominal.name_length = length;
        transfer_policy_part(L, reader, owner, 2);
        luaL_checktype(L, -1, LUA_TSTRING);
        bytes = lua_tolstring(L, -1, &length);
        node->as.nominal.bytes = transfer_copy(L, state->graph, bytes, length);
        node->as.nominal.length = length;
        break;
    case 10:
        node->kind = TRANSFER_CLOSURE;
        if (!titan_transfer_is_closure(L, -1))
            luaL_error(L, "cannot transfer a value that is not a Titan closure");
        transfer_encode_closure(L, state, lua_gettop(L), depth, node);
        break;
    case 11: {
        Table *mutable_mt, *const_mt, *array;
        TValue value;
        TransferActive active;
        lua_Unsigned count;
        unsigned i;
        node->kind = TRANSFER_RECORD_PAYLOAD;
        luaL_checktype(L, -1, LUA_TSTRING);
        bytes = lua_tolstring(L, -1, &length);
        node->as.payload.name = transfer_copy(L, state->graph, bytes, length);
        node->as.payload.name_length = length;
        node->as.payload.module = transfer_record_module(L, -1);
        transfer_policy_part(L, reader, owner, 2);
        value = lua_totvalue(L, -1);
        titan_array_cached_metatables(L, &mutable_mt, &const_mt);
        (void)const_mt;
        array = mutable_mt == NULL ? NULL
            : titan_array_try_backing(&value, mutable_mt);
        if (array == NULL)
            luaL_error(L, "custom transfer payload requires a mutable Titan Array");
        count = titan_array_length(array);
        if (count > UINT_MAX || count > SIZE_MAX / sizeof(TransferNode *))
            luaL_error(L, "custom transfer payload is too large");
        node->as.payload.count = (unsigned)count;
        node->as.payload.values = (TransferNode **)transfer_allocate(L,
            &state->graph->allocations, (size_t)count * sizeof(TransferNode *));
        transfer_enter(L, state, &active, array, "custom transfer payload");
        for (i = 0; i < node->as.payload.count; ++i) {
            titan_array_get(array, (lua_Integer)i + 1, &value);
            lua_pushtvalue(L, value);
            node->as.payload.values[i] = transfer_encode_policy(L, state,
                lua_gettop(L), depth + 1);
            lua_pop(L, 1);
        }
        state->active = active.previous;
        break;
    }
    default: luaL_error(L, "TransferValue has an invalid variant tag");
    }
    lua_settop(L, top);
    return node;
}

static TransferNode *transfer_encode_nominal(lua_State *L, TransferEncoder *state,
                                              int index, unsigned depth) {
    int top = lua_gettop(L);
    TransferNode *node;
    TransferActive active;
    TValue value = lua_totvalue(L, index);
    lua_Integer brand;
    if (transfer_is_policy(L, index)) {
        node = (TransferNode *)transfer_allocate(L, &state->graph->allocations,
                                                sizeof(TransferNode));
        node->kind = TRANSFER_POLICY_WRAPPER;
        node->as.policy = transfer_encode_policy(L, state, index, depth + 1);
        return node;
    }
    if (!lua_getmetatable(L, index))
        luaL_error(L, "cannot transfer userdata captured by a Titan closure");
    lua_rawgetp(L, -1, TITAN_BRAND);
    brand = lua_tointeger(L, -1);
    lua_settop(L, top);
    if (brand != TITAN_RECORD && brand != TITAN_UNION)
        luaL_error(L, "cannot transfer this userdata captured by a Titan closure");
    transfer_enter(L, state, &active, uvalue(&value), "custom transfer record");
    transfer_policy_function(L, "from_value");
    lua_pushvalue(L, index);
    lua_call(L, 1, 1);
    node = transfer_encode_policy(L, state, lua_gettop(L), depth);
    lua_settop(L, top);
    state->active = active.previous;
    return node;
}

static TransferNode *transfer_encode_value(lua_State *L, TransferEncoder *state,
                                           int index, unsigned depth) {
    TransferNode *node;
    size_t length;
    const char *bytes;
    TValue value;
    if (depth > TITAN_TRANSFER_MAX_DEPTH)
        luaL_error(L, "Titan closure transfer exceeds its capture depth limit");
    luaL_checkstack(L, 6, "encoding a Titan closure capture");
    index = lua_absindex(L, index);
    if (lua_type(L, index) == LUA_TUSERDATA)
        return transfer_encode_nominal(L, state, index, depth);
    node = (TransferNode *)transfer_allocate(L, &state->graph->allocations,
                                            sizeof(TransferNode));
    switch (lua_type(L, index)) {
    case LUA_TNIL: node->kind = TRANSFER_NIL; break;
    case LUA_TBOOLEAN:
        node->kind = TRANSFER_BOOLEAN;
        node->as.boolean = lua_toboolean(L, index);
        break;
    case LUA_TNUMBER:
        if (lua_isinteger(L, index)) {
            node->kind = TRANSFER_INTEGER;
            node->as.integer = lua_tointeger(L, index);
        } else {
            node->kind = TRANSFER_NUMBER;
            node->as.number = lua_tonumber(L, index);
        }
        break;
    case LUA_TSTRING:
        node->kind = TRANSFER_STRING;
        bytes = lua_tolstring(L, index, &length);
        node->as.string.bytes = transfer_copy(L, state->graph, bytes, length);
        node->as.string.length = length;
        break;
    case LUA_TLIGHTUSERDATA:
        node->kind = TRANSFER_POINTER;
        node->as.pointer = lua_touserdata(L, index);
        break;
    case LUA_TFUNCTION:
        value = lua_totvalue(L, index);
        if (transfer_branded(&value)) {
            node->kind = TRANSFER_CLOSURE;
            transfer_encode_closure(L, state, index, depth, node);
        } else if (ttislcf(&value)
                   || (ttisCclosure(&value) && clCvalue(&value)->nupvalues == 0)) {
            node->kind = TRANSFER_CFUNCTION;
            node->as.function = lua_tocfunction(L, index);
        } else luaL_error(L, "cannot transfer a non-Titan closure capture");
        break;
    default:
        luaL_error(L, "cannot transfer a %s captured by a Titan closure",
                   luaL_typename(L, index));
    }
    return node;
}

static void transfer_encode_root(lua_State *L, TitanTransferGraph *graph,
                                  int index, int policy) {
    TransferEncoder state;
    int top = lua_gettop(L);
    index = lua_absindex(L, index);
    if (graph == NULL) luaL_error(L, "cannot allocate Titan closure transfer");
    if (graph->started) luaL_error(L, "Titan closure transfer was already encoded");
    graph->started = 1;
    graph->policy_root = policy;
    if (!policy && !titan_transfer_is_closure(L, index))
        luaL_error(L, "Titan closure transfer requires a Titan closure");
    memset(&state, 0, sizeof(state));
    state.graph = graph;
    luaL_checkstack(L, 1, "rooting Titan closure capture identities");
    lua_newtable(L);
    state.box_roots = lua_gettop(L);
    graph->root = policy ? transfer_encode_policy(L, &state, index, 0)
                        : transfer_encode_value(L, &state, index, 0);
    transfer_free_allocations(graph->scratch);
    graph->scratch = NULL;
    lua_settop(L, top);
}

void titan_transfer_encode(lua_State *L, TitanTransferGraph *graph, int index) {
    transfer_encode_root(L, graph, index, 0);
}

void titan_transfer_encode_policy(lua_State *L, TitanTransferGraph *graph,
                                   int index) {
    transfer_encode_root(L, graph, index, 1);
}

static void transfer_decode_policy(lua_State *L, const TransferNode *node,
                                    int boxes, unsigned depth);

static void transfer_decode_value(lua_State *L, const TransferNode *node,
                                   int boxes, unsigned depth) {
    unsigned i;
    if (depth > TITAN_TRANSFER_MAX_DEPTH)
        luaL_error(L, "Titan closure transfer exceeds its capture depth limit");
    luaL_checkstack(L, 7, "decoding a Titan closure capture");
    switch (node->kind) {
    case TRANSFER_NIL: lua_pushnil(L); break;
    case TRANSFER_BOOLEAN: lua_pushboolean(L, node->as.boolean); break;
    case TRANSFER_INTEGER: lua_pushinteger(L, node->as.integer); break;
    case TRANSFER_NUMBER: lua_pushnumber(L, node->as.number); break;
    case TRANSFER_STRING:
        lua_pushlstring(L, node->as.string.bytes, node->as.string.length);
        break;
    case TRANSFER_POINTER:
    case TRANSFER_LUA_STATE: lua_pushlightuserdata(L, node->as.pointer); break;
    case TRANSFER_CFUNCTION: lua_pushcfunction(L, node->as.function); break;
    case TRANSFER_NOMINAL:
        transfer_protobuf_function(L, "deserialize_nominal");
        lua_pushlstring(L, node->as.nominal.bytes, node->as.nominal.length);
        lua_pushlstring(L, node->as.nominal.name, node->as.nominal.name_length);
        lua_pushboolean(L, node->as.nominal.is_union);
        lua_call(L, 3, 1);
        break;
    case TRANSFER_CLOSURE: {
        int top = lua_gettop(L);
        Udata *module = transfer_module(L, node->as.closure.module, 1);
        const TitanTransferEntry *entry = node->as.closure.entry;
        int slots;
        lua_createtable(L, (int)entry->capture_count, 0);
        slots = lua_gettop(L);
        for (i = 0; i < entry->capture_count; ++i) {
            const TransferCapture *capture = &node->as.closure.captures[i];
            if (capture->value->kind == TRANSFER_BOX_REFERENCE) {
                lua_rawgeti(L, boxes, capture->value->as.box);
                if (lua_type(L, -1) != LUA_TUSERDATA)
                    luaL_error(L, "Titan closure transfer has an unresolved capture box");
            } else {
                int semantic;
                transfer_decode_value(L, capture->value, boxes, depth + 1);
                semantic = lua_gettop(L);
                entry->restore_capture(L, module, i, semantic);
                if (lua_gettop(L) != semantic + 1)
                    luaL_error(L, "Titan closure capture reconstruction changed the stack");
                lua_remove(L, semantic);
                if (capture->box != 0) {
                    if (lua_type(L, -1) != LUA_TUSERDATA)
                        luaL_error(L, "Titan closure capture reconstruction did not return a box");
                    lua_pushvalue(L, -1);
                    lua_rawseti(L, boxes, capture->box);
                }
            }
            lua_rawseti(L, slots, i + 1);
        }
        entry->restore(L, module, slots);
        if (lua_gettop(L) != slots + 1 || !titan_transfer_is_closure(L, -1))
            luaL_error(L, "Titan closure reconstruction did not return a closure");
        lua_copy(L, -1, top + 1);
        lua_settop(L, top + 1);
        break;
    }
    case TRANSFER_RECORD_PAYLOAD: {
        int top = lua_gettop(L);
        transfer_decode_policy(L, node, boxes, depth);
        transfer_policy_to_value(L, top + 1);
        lua_remove(L, top + 1);
        break;
    }
    case TRANSFER_POLICY_WRAPPER:
        transfer_decode_policy(L, node->as.policy, boxes, depth + 1);
        break;
    default: luaL_error(L, "Titan closure transfer has an invalid capture node");
    }
}

/* A decoded mutable payload Array has the same exact union-write policy as a
 * generated {TransferValue}. The canonical destination metatable is retained
 * in the writer closure; no source-state type or object is referenced. */
static int transfer_policy_array_writer(lua_State *L) {
    if (lua_type(L, 1) != LUA_TUSERDATA || !lua_getmetatable(L, 1))
        return luaL_error(L, "transfer payload Array requires TransferValue");
    if (!lua_rawequal(L, -1, lua_upvalueindex(1)))
        return luaL_error(L, "transfer payload Array requires TransferValue");
    lua_settop(L, 1);
    return 1;
}

static Table *transfer_policy_array(lua_State *L, unsigned count) {
    Table *metatable;
    Table *array;
    TValue writer;
    int top = lua_gettop(L);
    luaL_checkstack(L, 2, "rebuilding a Titan transfer payload Array");
    luaL_getmetatable(L, "Titan union titan.async.TransferValue metatable");
    if (!lua_istable(L, -1))
        luaL_error(L, "destination has no TransferValue metatable");
    lua_pushcclosure(L, transfer_policy_array_writer, 1);
    writer = lua_totvalue(L, -1);
    metatable = titan_array_metatable(L);
    lua_pushnil(L);
    array = titan_array_new(L, metatable, count, &writer, L->top.p - 1);
    setuvalue(L, s2v(L->top.p - 1), titan_array_require_proxy(array));
    lua_remove(L, top + 1);
    return array;
}

/* Lua-facing union constructors deliberately reject implicit conversion from
 * lightuserdata to foreign pointers. These three policies already carry exact
 * native pointer bits, so use the ordinary reflected projection constructor,
 * which performs that explicit storage conversion without interpreting layout.
 * The module and projection stay rooted while the constructor may collect. */
static void transfer_native_policy(lua_State *L, lua_Integer tag, void *pointer) {
    typedef void (*Constructor)(lua_State *, Udata *, lua_Integer, TValue *, TValue *);
    int top = lua_gettop(L);
    Constructor constructor;
    Udata *module;
    Table *parts;
    TValue input, output;
    luaL_checkstack(L, 5, "rebuilding a native Titan transfer policy");
    transfer_library(L, "titan.async");
    lua_pop(L, 1);
    luaL_getmetatable(L, "Titan union titan.async.TransferValue metatable");
    if (!lua_istable(L, -1))
        luaL_error(L, "destination has no TransferValue metatable");
    lua_rawgetp(L, -1, TITAN_MT_CONSTRUCT);
    constructor = titan_cast_func(Constructor, lua_touserdata(L, -1));
    if (constructor == NULL)
        luaL_error(L, "TransferValue has no reflected constructor");
    lua_pop(L, 1);
    lua_rawgetp(L, -1, TITAN_MT_MOD);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        luaL_error(L, "TransferValue has no destination module owner");
    module = uvalue(s2v(L->top.p - 1));
    parts = titan_reflect_projection_array(L, 1);
    lua_pushlightuserdata(L, pointer);
    titan_reflect_projection_put(L, parts, 1);
    input = lua_totvalue(L, -1);
    setnilvalue(&output);
    constructor(L, module, tag, &input, &output);
    lua_pushtvalue(L, output);
    if (!transfer_is_policy(L, -1))
        luaL_error(L, "native transfer reconstruction did not return a policy");
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}

static void transfer_decode_policy(lua_State *L, const TransferNode *node,
                                    int boxes, unsigned depth) {
    int top = lua_gettop(L);
    int nargs = 1;
    if (depth > TITAN_TRANSFER_MAX_DEPTH)
        luaL_error(L, "Titan transfer exceeds its payload depth limit");
    luaL_checkstack(L, 7, "decoding a Titan transfer policy");
    switch (node->kind) {
    case TRANSFER_NIL:
        transfer_policy_function(L, "is_nil");
        nargs = 0;
        break;
    case TRANSFER_BOOLEAN:
        transfer_policy_function(L, "is_boolean");
        lua_pushboolean(L, node->as.boolean);
        break;
    case TRANSFER_INTEGER:
        transfer_policy_function(L, "is_integer");
        lua_pushinteger(L, node->as.integer);
        break;
    case TRANSFER_NUMBER:
        transfer_policy_function(L, "is_float");
        lua_pushnumber(L, node->as.number);
        break;
    case TRANSFER_STRING:
        transfer_policy_function(L, "is_string");
        lua_pushlstring(L, node->as.string.bytes, node->as.string.length);
        break;
    case TRANSFER_LUA_STATE:
        transfer_native_policy(L, 5, node->as.pointer);
        return;
    case TRANSFER_POINTER:
        transfer_native_policy(L, 7, node->as.pointer);
        return;
    case TRANSFER_CFUNCTION:
        transfer_native_policy(L, 6, titan_cast_func(void *, node->as.function));
        return;
    case TRANSFER_NOMINAL:
        transfer_policy_function(L,
            node->as.nominal.is_union ? "is_union" : "is_record");
        lua_pushlstring(L, node->as.nominal.name, node->as.nominal.name_length);
        lua_pushlstring(L, node->as.nominal.bytes, node->as.nominal.length);
        nargs = 2;
        break;
    case TRANSFER_CLOSURE:
        transfer_policy_function(L, "is_closure");
        transfer_decode_value(L, node, boxes, depth);
        break;
    case TRANSFER_RECORD_PAYLOAD: {
        Table *array;
        unsigned i;
        transfer_module(L, node->as.payload.module, 1);
        transfer_policy_function(L, "is_record_payload");
        lua_pushlstring(L, node->as.payload.name, node->as.payload.name_length);
        array = transfer_policy_array(L, node->as.payload.count);
        for (i = 0; i < node->as.payload.count; ++i) {
            transfer_decode_policy(L, node->as.payload.values[i], boxes, depth + 1);
            titan_array_set_stack(L, array, (lua_Integer)i + 1, -1);
            lua_pop(L, 1);
        }
        lua_call(L, 2, 1);
        if (!transfer_is_policy(L, -1))
            luaL_error(L, "custom transfer reconstruction did not return a policy");
        lua_copy(L, -1, top + 1);
        lua_settop(L, top + 1);
        return;
    }
    default: luaL_error(L, "Titan transfer has an invalid policy node");
    }
    lua_call(L, nargs, 1);
    if (!transfer_is_policy(L, -1))
        luaL_error(L, "Titan transfer reconstruction did not return a policy");
}

static void transfer_decode_root(lua_State *L, const TitanTransferGraph *graph,
                                  int policy) {
    int top = lua_gettop(L);
    int boxes;
    if (graph == NULL || graph->root == NULL)
        luaL_error(L, "Titan closure transfer is incomplete");
    if (graph->policy_root != policy)
        luaL_error(L, "Titan transfer graph has a different root policy");
    luaL_checkstack(L, 2, "decoding a Titan closure transfer");
    lua_newtable(L);
    boxes = lua_gettop(L);
    if (policy) transfer_decode_policy(L, graph->root, boxes, 0);
    else transfer_decode_value(L, graph->root, boxes, 0);
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}

void titan_transfer_decode(lua_State *L, const TitanTransferGraph *graph) {
    transfer_decode_root(L, graph, 0);
}

void titan_transfer_decode_policy(lua_State *L, const TitanTransferGraph *graph) {
    transfer_decode_root(L, graph, 1);
}
