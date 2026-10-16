#include <stdlib.h>
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
    TRANSFER_CLOSURE, TRANSFER_BOX_REFERENCE
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
};

typedef struct TransferActive {
    const struct TransferActive *previous;
    const CClosure *identity;
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

static void transfer_protobuf_function(lua_State *L, const char *name) {
    int top = lua_gettop(L);
    lua_CFunction loader;
    luaL_checkstack(L, 4, "loading Titan transfer protobuf");
    lua_pushliteral(L, LUA_PRELOAD_TABLE);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1))
        luaL_error(L, "Titan closure transfer has no native protobuf loader");
    lua_pushliteral(L, "titan.protobuf");
    lua_rawget(L, -2);
    loader = lua_tocfunction(L, -1);
    if (loader == NULL || lua_getupvalue(L, -1, 1) != NULL)
        luaL_error(L, "Titan closure transfer has no native protobuf loader");
    lua_settop(L, top);
    luaL_requiref(L, "titan.protobuf", loader, 0);
    lua_getfield(L, -1, name);
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
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

static void transfer_encode_nominal(lua_State *L, TransferEncoder *state,
                                     int index, TransferNode *node) {
    int top = lua_gettop(L);
    const void *metatable;
    lua_Integer brand;
    const char *text;
    size_t length;
    if (!lua_getmetatable(L, index))
        luaL_error(L, "cannot transfer userdata captured by a Titan closure");
    metatable = lua_topointer(L, -1);
    lua_rawgetp(L, -1, TITAN_BRAND);
    brand = lua_tointeger(L, -1);
    lua_settop(L, top);
    if (brand != TITAN_RECORD && brand != TITAN_UNION)
        luaL_error(L, "cannot transfer this userdata captured by a Titan closure");
    lua_rawgetp(L, LUA_REGISTRYINDEX, metatable);
    if (lua_type(L, -1) != LUA_TSTRING)
        luaL_error(L, "Titan closure nominal capture has no registered name");
    text = lua_tolstring(L, -1, &length);
    node->as.nominal.name = transfer_copy(L, state->graph, text, length);
    node->as.nominal.name_length = length;
    transfer_protobuf_function(L, "serialize");
    lua_pushvalue(L, index);
    lua_call(L, 1, 1);
    if (lua_type(L, -1) != LUA_TSTRING)
        luaL_error(L, "Titan closure nominal serialization did not return bytes");
    text = lua_tolstring(L, -1, &length);
    node->as.nominal.bytes = transfer_copy(L, state->graph, text, length);
    node->as.nominal.length = length;
    node->as.nominal.is_union = brand == TITAN_UNION;
    lua_settop(L, top);
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
    case LUA_TUSERDATA:
        node->kind = TRANSFER_NOMINAL;
        transfer_encode_nominal(L, state, index, node);
        break;
    default:
        luaL_error(L, "cannot transfer a %s captured by a Titan closure",
                   luaL_typename(L, index));
    }
    return node;
}

void titan_transfer_encode(lua_State *L, TitanTransferGraph *graph, int index) {
    TransferEncoder state;
    int top = lua_gettop(L);
    index = lua_absindex(L, index);
    if (graph == NULL) luaL_error(L, "cannot allocate Titan closure transfer");
    if (graph->started) luaL_error(L, "Titan closure transfer was already encoded");
    graph->started = 1;
    if (!titan_transfer_is_closure(L, index))
        luaL_error(L, "Titan closure transfer requires a Titan closure");
    memset(&state, 0, sizeof(state));
    state.graph = graph;
    luaL_checkstack(L, 1, "rooting Titan closure capture identities");
    lua_newtable(L);
    state.box_roots = lua_gettop(L);
    graph->root = transfer_encode_value(L, &state, index, 0);
    transfer_free_allocations(graph->scratch);
    graph->scratch = NULL;
    lua_settop(L, top);
}

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
    case TRANSFER_POINTER: lua_pushlightuserdata(L, node->as.pointer); break;
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
    default: luaL_error(L, "Titan closure transfer has an invalid capture node");
    }
}

void titan_transfer_decode(lua_State *L, const TitanTransferGraph *graph) {
    int top = lua_gettop(L);
    int boxes;
    if (graph == NULL || graph->root == NULL)
        luaL_error(L, "Titan closure transfer is incomplete");
    luaL_checkstack(L, 2, "decoding a Titan closure transfer");
    lua_newtable(L);
    boxes = lua_gettop(L);
    transfer_decode_value(L, graph->root, boxes, 0);
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}
