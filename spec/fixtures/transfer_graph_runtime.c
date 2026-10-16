#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Inject native arena failures without changing Lua's own allocator. Each
 * unsuccessful encode must be completely recoverable through the published
 * graph owner, including allocations made before a later projection raises. */
static int allocation_budget = -1;
static unsigned allocations;
static void *graph_malloc(size_t size) {
    void *result;
    if (allocation_budget == 0) return NULL;
    if (allocation_budget > 0) --allocation_budget;
    result = malloc(size);
    if (result != NULL) ++allocations;
    return result;
}
static void *graph_calloc(size_t count, size_t size) {
    void *result = graph_malloc(count * size);
    if (result != NULL) memset(result, 0, count * size);
    return result;
}
static void graph_free(void *pointer) {
    if (pointer != NULL) {
        assert(allocations != 0);
        --allocations;
        free(pointer);
    }
}
#define malloc graph_malloc
#define calloc graph_calloc
#define free graph_free
#include "titan-runtime/transfer.c"
#undef malloc
#undef calloc
#undef free

/* Policy graphs use the real dense Array implementation. Native traceback
 * symbolization is unrelated to these ownership checks. */
#define TITAN_NO_LIBBACKTRACE
#undef lua_assert
#define lua_assert(condition) assert(condition)
#if defined(_WIN32) && defined(__clang__)
/* Embedding the Array implementation also brings in private Windows loader
 * helpers which this standalone fixture does not use. Keep the fixture's own
 * strict warnings, and the ordinary runtime build flags, unchanged. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#endif
#include "titan-runtime/titan.c"
#if defined(_WIN32) && defined(__clang__)
#pragma clang diagnostic pop
#endif

static char outer_native, inner_native, leaf_native, detaching_native, function_tag;
static unsigned module_initializations;
static int reconstruction_budget = -1;
static void *fixture_symbols(const char *name);
static void register_custom_record(lua_State *L, Udata *module);

static int fixture_entry(lua_State *L) {
    (void)L;
    return 0;
}

static Udata *fixture_init(lua_State *L) {
    Udata *module;
    ++module_initializations;
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module transfer.runtime.fixture");
    if (lua_type(L, -1) == LUA_TUSERDATA) {
        module = uvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        return module;
    }
    lua_pop(L, 1);
    ((TitanModuleData *)lua_newuserdatauv(L, sizeof(TitanModuleData), 0))
        ->symbols = fixture_symbols;
    module = uvalue(s2v(L->top.p - 1));
    lua_setfield(L, LUA_REGISTRYINDEX, "Titan module transfer.runtime.fixture");
    register_custom_record(L, module);
    lua_gc(L, LUA_GCCOLLECT);
    return module;
}

static void fail_reconstruction(lua_State *L) {
    if (reconstruction_budget == 0)
        luaL_error(L, "injected capture reconstruction failure");
    if (reconstruction_budget > 0) --reconstruction_budget;
}

static void project_box(lua_State *L, CClosure *closure, unsigned index) {
    const TValue *slot = &closure->upvalue[index + 4];
    assert(ttisfulluserdata(slot));
    assert(uvalue(slot)->len == sizeof(lua_Integer));
    lua_pushinteger(L, *(lua_Integer *)getudatamem(uvalue(slot)));
    lua_gc(L, LUA_GCCOLLECT);
}

static void project_outer(lua_State *L, CClosure *closure, unsigned index) {
    if (index == 0) project_box(L, closure, index);
    else {
        assert(index == 1);
        lua_pushtvalue(L, closure->upvalue[5]);
        lua_gc(L, LUA_GCCOLLECT);
    }
}

static void project_leaf(lua_State *L, CClosure *closure, unsigned index) {
    assert(index == 0);
    lua_pushtvalue(L, closure->upvalue[4]);
    lua_gc(L, LUA_GCCOLLECT);
}

static void restore_box(lua_State *L, Udata *module, unsigned index, int value) {
    lua_Integer number;
    (void)module;
    assert(index == 0);
    fail_reconstruction(L);
    number = luaL_checkinteger(L, value);
    *(lua_Integer *)lua_newuserdatauv(L, sizeof(lua_Integer), 0) = number;
    lua_gc(L, LUA_GCCOLLECT);
}

static void restore_outer_capture(lua_State *L, Udata *module, unsigned index,
                                  int value) {
    if (index == 0) restore_box(L, module, index, value);
    else {
        assert(index == 1);
        fail_reconstruction(L);
        lua_pushvalue(L, value);
        lua_gc(L, LUA_GCCOLLECT);
    }
}

static void restore_leaf_capture(lua_State *L, Udata *module, unsigned index,
                                 int value) {
    (void)module;
    assert(index == 0);
    fail_reconstruction(L);
    lua_pushvalue(L, value);
    lua_gc(L, LUA_GCCOLLECT);
}

static void restore_closure(lua_State *L, Udata *module, int slots,
                            void *native, unsigned count) {
    unsigned i;
    luaL_checkstack(L, (int)count + 5, "constructing test closure");
    titan_pushmodule(L, module);
    lua_pushlightuserdata(L, &function_tag);
    lua_pushlightuserdata(L, native);
    lua_pushlightuserdata(L, TITAN_BRAND);
    for (i = 0; i < count; ++i) lua_rawgeti(L, slots, i + 1);
    lua_pushcfunction(L, fixture_entry);
    lua_pushcclosure(L, fixture_entry, (int)count + 5);
    lua_gc(L, LUA_GCCOLLECT);
}

static void restore_outer(lua_State *L, Udata *module, int slots) {
    restore_closure(L, module, slots, &outer_native, 2);
}
static void restore_inner(lua_State *L, Udata *module, int slots) {
    restore_closure(L, module, slots, &inner_native, 1);
}
static void restore_leaf(lua_State *L, Udata *module, int slots) {
    restore_closure(L, module, slots, &leaf_native, 1);
}

/* Reentrant collection may detach a nested closure which was visited before
 * a later capture. Every raw identity still in the encoder's dedup map must
 * remain live, independently of the mutable source graph. */
static unsigned detached;
static int detach_child(lua_State *L) {
    TValue parent_box = lua_totvalue(L, lua_upvalueindex(1));
    setnilvalue(&uvalue(&parent_box)->uv[0].uv);
    ++detached;
    return 0;
}
static void project_detaching(lua_State *L, CClosure *closure, unsigned index) {
    Udata *box = uvalue(&closure->upvalue[4]);
    if (index == 0) {
        lua_pushtvalue(L, box->uv[0].uv);
        return;
    }
    assert(index == 1);
    luaL_checkstack(L, 5, "preparing reentrant collection");
    lua_pushinteger(L, 7);
    lua_newuserdatauv(L, 0, 0);
    lua_newtable(L);
    lua_pushtvalue(L, closure->upvalue[4]);
    lua_pushcclosure(L, detach_child, 1);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT);
    lua_gc(L, LUA_GCCOLLECT);
    assert(detached == 1);
    lua_getfield(L, LUA_REGISTRYINDEX, "transfer fixture weak identities");
    lua_rawgeti(L, -1, 1);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        luaL_error(L, "previously encoded capture box lost its root during reentrant collection");
    lua_pop(L, 2);
}
static void restore_detaching_capture(lua_State *L, Udata *module,
                                      unsigned index, int value) {
    (void)module;
    if (index == 0) {
        lua_newuserdatauv(L, 0, 1);
        lua_pushvalue(L, value);
        lua_setiuservalue(L, -2, 1);
    } else {
        assert(index == 1);
        lua_pushvalue(L, value);
    }
}
static void restore_detaching(lua_State *L, Udata *module, int slots) {
    restore_closure(L, module, slots, &detaching_native, 2);
}
static const unsigned char detaching_boxes[] = { 1, 0 };

static const unsigned char outer_boxes[] = { 1, 0 };
static const unsigned char inner_boxes[] = { 1 };
static const unsigned char leaf_boxes[] = { 0 };
static const TitanTransferEntry entries[] = {
    { &outer_native, fixture_entry, fixture_entry, 2, outer_boxes,
      project_outer, restore_outer_capture, restore_outer, TITAN_TRANSFER_SOURCE },
    { &inner_native, fixture_entry, fixture_entry, 1, inner_boxes,
      project_box, restore_box, restore_inner, TITAN_TRANSFER_SOURCE },
    { &detaching_native, fixture_entry, fixture_entry, 2, detaching_boxes,
      project_detaching, restore_detaching_capture, restore_detaching, TITAN_TRANSFER_SOURCE },
    { &leaf_native, fixture_entry, fixture_entry, 1, leaf_boxes,
      project_leaf, restore_leaf_capture, restore_leaf, TITAN_TRANSFER_SOURCE },
};
static const TitanTransferModule fixture_module = {
    "transfer.runtime.fixture", fixture_init, fixture_symbols, 4, entries
};
static void *fixture_symbols(const char *name) {
    return strcmp(name, TITAN_TRANSFER_MANIFEST_SYMBOL) == 0
        ? (void *)&fixture_module : NULL;
}
static void *different_symbols(const char *name) {
    (void)name;
    return NULL;
}

/* This small native async facade exercises the graph independently of an
 * installed standard library. Its nominal layout and payload-reader protocol
 * match generated unions; the actual dense Arrays come from titan.c above. */
#define POLICY_MT "Titan union titan.transfer.TransferValue metatable"
#define CUSTOM_MT "transfer fixture custom record"
#define CUSTOM_NAME "transfer.runtime.fixture.Custom"
static unsigned custom_reconstructions;

static void policy_reader(lua_State *L, Udata *owner, lua_Integer index,
                           TValue *result) {
    (void)L;
    if (index == 0) {
        setivalue(result, *(int *)getudatamem(owner));
    } else {
        assert(index >= 1 && index <= 2);
        *result = owner->uv[index - 1].uv;
    }
}

static void push_policy(lua_State *L, int tag, int first, int second) {
    int top = lua_gettop(L);
    if (first != 0) first = lua_absindex(L, first);
    if (second != 0) second = lua_absindex(L, second);
    *(int *)lua_newuserdatauv(L, sizeof(int), 2) = tag;
    luaL_setmetatable(L, POLICY_MT);
    if (first != 0) {
        lua_pushvalue(L, first);
        lua_setiuservalue(L, top + 1, 1);
    }
    if (second != 0) {
        lua_pushvalue(L, second);
        lua_setiuservalue(L, top + 1, 2);
    }
    lua_gc(L, LUA_GCCOLLECT);
}

static int policy_constructor(lua_State *L) {
    int tag = (int)lua_tointeger(L, lua_upvalueindex(1));
    if (tag >= 5 && tag <= 7)
        return luaL_error(L, "implicit dynamic coercion to foreign pointer is unavailable");
    push_policy(L, tag, tag == 0 ? 0 : 1, tag >= 8 && tag != 10 ? 2 : 0);
    return 1;
}

static void policy_native_constructor(lua_State *L, Udata *module,
    lua_Integer tag, TValue *input, TValue *output) {
    int top = lua_gettop(L);
    Table *parts = titan_reflect_projection_input(L, input, 1);
    TValue pointer;
    (void)module;
    assert(tag >= 5 && tag <= 7);
    titan_array_get(parts, 1, &pointer);
    assert(ttislightuserdata(&pointer));
    lua_pushtvalue(L, pointer);
    push_policy(L, (int)tag, -1, 0);
    *output = lua_totvalue(L, -1);
    lua_settop(L, top);
}

static void push_custom_record(lua_State *L, int payload) {
    payload = lua_absindex(L, payload);
    lua_newuserdatauv(L, 0, 1);
    luaL_setmetatable(L, CUSTOM_MT);
    lua_pushvalue(L, payload);
    lua_setiuservalue(L, -2, 1);
    lua_gc(L, LUA_GCCOLLECT);
}

static int policy_from_value(lua_State *L) {
    if (transfer_is_policy(L, 1)) {
        lua_settop(L, 1);
        return 1;
    }
    luaL_checkudata(L, 1, CUSTOM_MT);
    lua_pushliteral(L, CUSTOM_NAME);
    lua_getiuservalue(L, 1, 1);
    push_policy(L, 11, -2, -1);
    return 1;
}

static int policy_to_value(lua_State *L) {
    int *tag = (int *)luaL_checkudata(L, 1, POLICY_MT);
    if (*tag == 11) {
        fail_reconstruction(L);
        ++custom_reconstructions;
        lua_getiuservalue(L, 1, 2);
        push_custom_record(L, -1);
    } else if (*tag == 0) lua_pushnil(L);
    else lua_getiuservalue(L, 1, 1);
    return 1;
}

static int async_loader(lua_State *L) {
    static const char *names[] = {
        "is_nil", "is_boolean", "is_integer", "is_float", "is_string",
        "is_lua_state", "is_function", "is_pointer", "is_record",
        "is_union", "is_closure", "is_record_payload"
    };
    unsigned i;
    luaL_newmetatable(L, POLICY_MT);
    lua_pushlightuserdata(L, titan_cast_func(void *, policy_reader));
    lua_rawsetp(L, -2, TITAN_MT_PAYLOAD);
    lua_pushinteger(L, TITAN_UNION);
    lua_rawsetp(L, -2, TITAN_BRAND);
    lua_pushlightuserdata(L, titan_cast_func(void *, policy_native_constructor));
    lua_rawsetp(L, -2, TITAN_MT_CONSTRUCT);
    ((TitanModuleData *)lua_newuserdatauv(L, sizeof(TitanModuleData), 0))->symbols = NULL;
    lua_rawsetp(L, -2, TITAN_MT_MOD);
    lua_newtable(L);
    lua_pushcfunction(L, policy_to_value);
    lua_setfield(L, -2, "to_value");
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_newtable(L);
    for (i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        lua_pushinteger(L, i);
        lua_pushcclosure(L, policy_constructor, 1);
        lua_setfield(L, -2, names[i]);
    }
    lua_pushcfunction(L, policy_from_value);
    lua_setfield(L, -2, "from_value");
    lua_setfield(L, -2, "TransferValue");
    return 1;
}

static void register_custom_record(lua_State *L, Udata *module) {
    int top = lua_gettop(L);
    luaL_newmetatable(L, CUSTOM_MT);
    lua_pushinteger(L, TITAN_RECORD);
    lua_rawsetp(L, -2, TITAN_BRAND);
    lua_pushboolean(L, 1);
    lua_rawsetp(L, -2, TITAN_MT_PUBLIC);
    titan_pushmodule(L, module);
    lua_rawsetp(L, -2, TITAN_MT_MOD);
    luaL_getsubtable(L, LUA_REGISTRYINDEX, TITAN_METATABLES_KEY);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, CUSTOM_NAME);
    lua_settop(L, top);
}

static lua_State *policy_state(int initialize_record) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, async_loader);
    lua_setfield(L, -2, "titan.transfer");
    lua_pop(L, 1);
    transfer_library(L, "titan.transfer");
    lua_pop(L, 1);
    if (initialize_record) fixture_init(L);
    return L;
}

static int encode_policy_call(lua_State *L) {
    int top = lua_gettop(L);
    titan_transfer_encode_policy(L, (TitanTransferGraph *)lua_touserdata(L, 2), -2);
    assert(lua_gettop(L) == top);
    return 0;
}
static int decode_policy_call(lua_State *L) {
    titan_transfer_decode_policy(L, (const TitanTransferGraph *)lua_touserdata(L, 1));
    return 1;
}
static int encode_policy(lua_State *L, TitanTransferGraph *graph) {
    lua_pushcfunction(L, encode_policy_call);
    lua_pushvalue(L, 1);
    lua_pushlightuserdata(L, graph);
    return lua_pcall(L, 2, 0, 0);
}
static int decode_policy(lua_State *L, const TitanTransferGraph *graph) {
    lua_pushcfunction(L, decode_policy_call);
    lua_pushlightuserdata(L, (void *)graph);
    return lua_pcall(L, 1, 1, 0);
}

static void wrap_leaf(lua_State *L, int value) {
    int top = lua_gettop(L);
    Udata *module = fixture_init(L);
    value = lua_absindex(L, value);
    lua_newtable(L);
    lua_pushvalue(L, value);
    lua_rawseti(L, -2, 1);
    restore_leaf(L, module, lua_gettop(L));
    lua_copy(L, -1, top + 1);
    lua_settop(L, top + 1);
}

static int encode_call(lua_State *L) {
    int top = lua_gettop(L);
    titan_transfer_encode(L, (TitanTransferGraph *)lua_touserdata(L, 2), -2);
    assert(lua_gettop(L) == top);
    return 0;
}
static int decode_call(lua_State *L) {
    titan_transfer_decode(L, (const TitanTransferGraph *)lua_touserdata(L, 1));
    return 1;
}
static int encode(lua_State *L, TitanTransferGraph *graph) {
    lua_pushcfunction(L, encode_call);
    lua_pushvalue(L, 1);
    lua_pushlightuserdata(L, graph);
    return lua_pcall(L, 2, 0, 0);
}
static int decode(lua_State *L, const TitanTransferGraph *graph) {
    lua_pushcfunction(L, decode_call);
    lua_pushlightuserdata(L, (void *)graph);
    return lua_pcall(L, 1, 1, 0);
}

static lua_State *make_outer(void) {
    lua_State *L = luaL_newstate();
    Udata *module;
    assert(L != NULL);
    module = fixture_init(L);
    *(lua_Integer *)lua_newuserdatauv(L, sizeof(lua_Integer), 0) = 42;
    lua_newtable(L);
    lua_pushvalue(L, 1);
    lua_rawseti(L, 2, 1);
    restore_inner(L, module, 2);
    lua_newtable(L);
    lua_pushvalue(L, 1);
    lua_rawseti(L, 4, 1);
    lua_pushvalue(L, 3);
    lua_rawseti(L, 4, 2);
    restore_outer(L, module, 4);
    lua_copy(L, -1, 1);
    lua_settop(L, 1);
    return L;
}

static lua_State *make_leaf(int kind) {
    lua_State *L = luaL_newstate();
    Udata *module;
    assert(L != NULL);
    module = fixture_init(L);
    lua_newtable(L);
    if (kind == 1) lua_newtable(L);
    else lua_pushlstring(L, "copied\0bytes", 12);
    lua_rawseti(L, 1, 1);
    restore_leaf(L, module, 1);
    lua_copy(L, -1, 1);
    lua_settop(L, 1);
    if (kind == 2) {
        lua_pushvalue(L, 1);
        assert(lua_setupvalue(L, 1, 5) != NULL);
    }
    return L;
}

static void test_native_allocation_failures(void) {
    lua_State *L = make_outer();
    int budget;
    for (budget = 0; budget < 100; ++budget) {
        TitanTransferGraph *graph;
        int status;
        allocation_budget = budget;
        graph = titan_transfer_new();
        if (graph == NULL) {
            assert(allocations == 0);
            continue;
        }
        status = encode(L, graph);
        allocation_budget = -1;
        if (status != LUA_OK) {
            assert(strstr(lua_tostring(L, -1), "cannot allocate") != NULL);
            lua_settop(L, 1);
        } else {
            assert(graph->scratch == NULL);
            assert(graph->box_count == 1);
        }
        titan_transfer_free(graph);
        assert(allocations == 0);
        if (status == LUA_OK) break;
    }
    assert(budget > 5 && budget < 100);
    lua_close(L);
}

static void test_source_retirement_and_aliases(void) {
    lua_State *origin = make_outer();
    lua_State *destination;
    TitanTransferGraph *graph = titan_transfer_new();
    CClosure *outer, *inner;
    Udata *box;
    unsigned before = module_initializations;
    int budget;
    assert(encode(origin, graph) == LUA_OK);
    lua_close(origin);
    destination = luaL_newstate();
    assert(destination != NULL);
    /* A failed decode must leave the immutable graph reusable, with no native
     * allocations or source-state entry needed during unwinding. */
    for (budget = 0; budget < 2; ++budget) {
        reconstruction_budget = budget;
        assert(decode(destination, graph) != LUA_OK);
        assert(strstr(lua_tostring(destination, -1), "injected") != NULL);
        lua_settop(destination, 0);
        lua_gc(destination, LUA_GCCOLLECT);
    }
    reconstruction_budget = -1;
    assert(decode(destination, graph) == LUA_OK);
    assert(module_initializations == before + 1);
    outer = clCvalue(s2v(destination->top.p - 1));
    box = uvalue(&outer->upvalue[4]);
    inner = clCvalue(&outer->upvalue[5]);
    assert(box == uvalue(&inner->upvalue[4]));
    assert(*(lua_Integer *)getudatamem(box) == 42);
    *(lua_Integer *)getudatamem(box) = 43;
    lua_gc(destination, LUA_GCCOLLECT);
    assert(*(lua_Integer *)getudatamem(uvalue(&inner->upvalue[4])) == 43);
    titan_transfer_free(graph);
    assert(allocations == 0);
    lua_close(destination);
}

static void test_binary_strings_and_provider_identity(void) {
    lua_State *origin = make_leaf(0);
    lua_State *destination = luaL_newstate();
    TitanTransferGraph *graph = titan_transfer_new();
    size_t length;
    const char *bytes;
    unsigned before;
    assert(destination != NULL);
    assert(encode(origin, graph) == LUA_OK);
    lua_close(origin);
    assert(decode(destination, graph) == LUA_OK);
    assert(lua_getupvalue(destination, -1, 5) != NULL);
    bytes = lua_tolstring(destination, -1, &length);
    assert(length == 12 && memcmp(bytes, "copied\0bytes", 12) == 0);
    lua_settop(destination, 0);
    ((TitanModuleData *)lua_newuserdatauv(destination,
        sizeof(TitanModuleData), 0))->symbols = different_symbols;
    lua_setfield(destination, LUA_REGISTRYINDEX,
        "Titan module transfer.runtime.fixture");
    before = module_initializations;
    assert(decode(destination, graph) != LUA_OK);
    assert(strstr(lua_tostring(destination, -1), "different provider") != NULL);
    assert(module_initializations == before);
    titan_transfer_free(graph);
    assert(allocations == 0);
    lua_close(destination);
}

static void test_rejected_graphs(void) {
    int kind;
    for (kind = 1; kind <= 2; ++kind) {
        lua_State *L = make_leaf(kind);
        TitanTransferGraph *graph = titan_transfer_new();
        assert(encode(L, graph) != LUA_OK);
        assert(strstr(lua_tostring(L, -1), kind == 1 ? "table" : "cyclic") != NULL);
        titan_transfer_free(graph);
        assert(allocations == 0);
        lua_close(L);
    }
}

static void test_reentrant_box_identity_roots(void) {
    lua_State *L = luaL_newstate();
    Udata *module;
    TitanTransferGraph *graph;
    int status;
    assert(L != NULL);
    detached = 0;
    module = fixture_init(L);
    *(lua_Integer *)lua_newuserdatauv(L, sizeof(lua_Integer), 0) = 42;
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "v");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    lua_pushvalue(L, 1);
    lua_rawseti(L, -2, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "transfer fixture weak identities");
    lua_newtable(L);
    lua_pushvalue(L, 1);
    lua_rawseti(L, 2, 1);
    restore_inner(L, module, 2);
    lua_newuserdatauv(L, 0, 1);
    lua_pushvalue(L, 3);
    lua_setiuservalue(L, 4, 1);
    lua_newtable(L);
    lua_pushvalue(L, 4);
    lua_rawseti(L, 5, 1);
    lua_pushinteger(L, 7);
    lua_rawseti(L, 5, 2);
    restore_detaching(L, module, 5);
    lua_copy(L, -1, 1);
    lua_settop(L, 1);
    graph = titan_transfer_new();
    status = encode(L, graph);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
    assert(graph->box_count == 2);
    /* Encode's private roots must disappear on success. Only the native graph
     * remains, so the detached origin box can now be collected. */
    lua_gc(L, LUA_GCCOLLECT);
    lua_getfield(L, LUA_REGISTRYINDEX, "transfer fixture weak identities");
    lua_rawgeti(L, -1, 1);
    assert(lua_isnil(L, -1));
    lua_close(L);
    L = luaL_newstate();
    assert(L != NULL);
    assert(decode(L, graph) == LUA_OK);
    {
        CClosure *parent = clCvalue(s2v(L->top.p - 1));
        Udata *cell = uvalue(&parent->upvalue[4]);
        CClosure *child = clCvalue(&cell->uv[0].uv);
        Udata *child_box = uvalue(&child->upvalue[4]);
        assert(*(lua_Integer *)getudatamem(child_box) == 42);
    }
    titan_transfer_free(graph);
    assert(allocations == 0);
    lua_close(L);
}

static lua_State *make_policy_packet(void) {
    lua_State *L = policy_state(1);
    Table *array = transfer_policy_array(L, 12);
    int tag;
    for (tag = 0; tag < 12; ++tag) {
        int top = lua_gettop(L);
        switch (tag) {
        case 0: break;
        case 1: lua_pushboolean(L, 0); break;
        case 2: lua_pushinteger(L, 42); break;
        case 3: lua_pushnumber(L, 1.25); break;
        case 4: lua_pushlstring(L, "a\0b", 3); break;
        case 5: lua_pushlightuserdata(L, NULL); break;
        case 6:
            lua_pushlightuserdata(L, titan_cast_func(void *, fixture_entry));
            break;
        case 7: lua_pushlightuserdata(L, &function_tag); break;
        case 8:
        case 9:
            lua_pushliteral(L, "packet nominal");
            lua_pushlstring(L, "\0wire", 5);
            break;
        case 10:
            lua_pushinteger(L, 77);
            wrap_leaf(L, -1);
            lua_remove(L, top + 1);
            break;
        case 11:
            lua_pushliteral(L, CUSTOM_NAME);
            transfer_policy_array(L, 0);
            break;
        }
        push_policy(L, tag, tag == 0 ? 0 : top + 1,
                    tag >= 8 && tag != 10 ? top + 2 : 0);
        titan_array_set_stack(L, array, tag + 1, -1);
        lua_settop(L, top);
    }
    lua_pushliteral(L, CUSTOM_NAME);
    push_policy(L, 11, -1, 1);
    lua_copy(L, -1, 1);
    lua_settop(L, 1);
    return L;
}

static int invalid_policy_array_write(lua_State *L) {
    lua_getiuservalue(L, 1, 2);
    lua_pushinteger(L, 42);
    lua_seti(L, -2, 1);
    return 0;
}

static void test_policy_variants_and_source_retirement(void) {
    lua_State *origin = make_policy_packet();
    lua_State *destination;
    TitanTransferGraph *graph = titan_transfer_new();
    unsigned before;
    Table *mutable_mt, *const_mt, *array;
    TValue value;
    int i, status;
    custom_reconstructions = 0;
    status = encode_policy(origin, graph);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(origin, -1));
    assert(status == LUA_OK);
    assert(graph->scratch == NULL);
    lua_close(origin);
    destination = policy_state(0);
    before = module_initializations;
    assert(decode(destination, graph) != LUA_OK);
    assert(strstr(lua_tostring(destination, -1), "different root policy") != NULL);
    lua_settop(destination, 0);
    assert(decode_policy(destination, graph) == LUA_OK);
    assert(module_initializations == before + 1);
    assert(custom_reconstructions == 0);
    assert(*(int *)luaL_checkudata(destination, 1, POLICY_MT) == 11);
    lua_getiuservalue(destination, 1, 2);
    value = lua_totvalue(destination, -1);
    titan_array_cached_metatables(destination, &mutable_mt, &const_mt);
    array = titan_array_try_backing(&value, mutable_mt);
    assert(array != NULL && titan_array_length(array) == 12);
    for (i = 0; i < 12; ++i) {
        Udata *policy;
        titan_array_get(array, i + 1, &value);
        assert(ttisfulluserdata(&value));
        policy = uvalue(&value);
        assert(*(int *)getudatamem(policy) == i);
        if (i == 1) assert(ttisfalse(&policy->uv[0].uv));
        if (i == 2) assert(ivalue(&policy->uv[0].uv) == 42);
        if (i == 4) {
            TString *bytes = tsvalue(&policy->uv[0].uv);
            assert(tsslen(bytes) == 3 && memcmp(getstr(bytes), "a\0b", 3) == 0);
        }
        if (i == 5) assert(pvalue(&policy->uv[0].uv) == NULL);
        if (i == 6) assert(pvalue(&policy->uv[0].uv)
                          == titan_cast_func(void *, fixture_entry));
        if (i == 7) assert(pvalue(&policy->uv[0].uv) == &function_tag);
        if (i == 10) {
            CClosure *closure = clCvalue(&policy->uv[0].uv);
            assert(ivalue(&closure->upvalue[4]) == 77);
        }
    }
    lua_settop(destination, 1);
    lua_pushcfunction(destination, invalid_policy_array_write);
    lua_pushvalue(destination, 1);
    assert(lua_pcall(destination, 1, 0, 0) != LUA_OK);
    assert(strstr(lua_tostring(destination, -1), "requires TransferValue") != NULL);
    lua_settop(destination, 1);
    transfer_policy_to_value(destination, 1);
    assert(luaL_testudata(destination, -1, CUSTOM_MT) != NULL);
    assert(custom_reconstructions == 1);
    titan_transfer_free(graph);
    assert(allocations == 0);
    lua_close(destination);
}

static void test_policy_allocation_failures(void) {
    lua_State *L = make_policy_packet();
    int budget;
    for (budget = 0; budget < 150; ++budget) {
        TitanTransferGraph *graph;
        int status;
        allocation_budget = budget;
        graph = titan_transfer_new();
        if (graph == NULL) {
            assert(allocations == 0);
            continue;
        }
        status = encode_policy(L, graph);
        allocation_budget = -1;
        if (status != LUA_OK) {
            assert(strstr(lua_tostring(L, -1), "cannot allocate") != NULL);
            lua_settop(L, 1);
        }
        titan_transfer_free(graph);
        assert(allocations == 0);
        if (status == LUA_OK) break;
    }
    assert(budget > 20 && budget < 150);
    lua_close(L);
}

static void test_custom_capture_and_policy_wrapper(void) {
    int wrapper;
    for (wrapper = 0; wrapper <= 1; ++wrapper) {
        lua_State *origin = make_policy_packet();
        lua_State *destination;
        TitanTransferGraph *graph = titan_transfer_new();
        if (!wrapper) {
            transfer_policy_to_value(origin, 1);
            lua_replace(origin, 1);
        }
        wrap_leaf(origin, 1);
        lua_replace(origin, 1);
        assert(encode(origin, graph) == LUA_OK);
        lua_close(origin);
        destination = policy_state(0);
        if (!wrapper) {
            reconstruction_budget = 0;
            assert(decode(destination, graph) != LUA_OK);
            assert(strstr(lua_tostring(destination, -1), "injected") != NULL);
            lua_settop(destination, 0);
            lua_gc(destination, LUA_GCCOLLECT);
            reconstruction_budget = -1;
        }
        assert(decode(destination, graph) == LUA_OK);
        assert(lua_getupvalue(destination, 1, 5) != NULL);
        assert(luaL_testudata(destination, -1, wrapper ? POLICY_MT : CUSTOM_MT));
        titan_transfer_free(graph);
        assert(allocations == 0);
        lua_close(destination);
    }
}

static void test_custom_payload_cycles(void) {
    int record_cycle;
    for (record_cycle = 0; record_cycle <= 1; ++record_cycle) {
        lua_State *L = policy_state(1);
        Table *array = transfer_policy_array(L, 1);
        TitanTransferGraph *graph = titan_transfer_new();
        lua_pushliteral(L, CUSTOM_NAME);
        push_policy(L, 11, 2, 1);
        if (record_cycle) {
            push_custom_record(L, 1);
            wrap_leaf(L, -1);
            push_policy(L, 10, -1, 0);
            titan_array_set_stack(L, array, 1, -1);
            lua_settop(L, 4);
            wrap_leaf(L, 4);
        } else {
            titan_array_set_stack(L, array, 1, 3);
            lua_pushvalue(L, 3);
        }
        lua_replace(L, 1);
        lua_settop(L, 1);
        assert((record_cycle ? encode(L, graph) : encode_policy(L, graph)) != LUA_OK);
        assert(strstr(lua_tostring(L, -1), "cyclic") != NULL);
        titan_transfer_free(graph);
        assert(allocations == 0);
        lua_close(L);
    }
}

static void test_invalid_policy_packets(void) {
    static const char *diagnostics[] = {
        "not initialized", "mutable Titan Array", "TransferValue entries",
        "NULL Lua C function"
    };
    int kind;
    for (kind = 0; kind < 4; ++kind) {
        lua_State *L = make_policy_packet();
        TitanTransferGraph *graph = titan_transfer_new();
        if (kind == 0) {
            lua_pushliteral(L, "unknown.Record");
            lua_setiuservalue(L, 1, 1);
        } else if (kind == 1) {
            lua_newtable(L);
            lua_setiuservalue(L, 1, 2);
        } else {
            Table *mutable_mt, *const_mt, *array;
            TValue value;
            lua_getiuservalue(L, 1, 2);
            value = lua_totvalue(L, -1);
            titan_array_cached_metatables(L, &mutable_mt, &const_mt);
            array = titan_array_try_backing(&value, mutable_mt);
            if (kind == 2) lua_pushinteger(L, 1);
            else {
                lua_pushlightuserdata(L, NULL);
                push_policy(L, 6, -1, 0);
            }
            /* Deliberately bypass the public Array writer to verify that the
             * native transport rejects malformed trusted-boundary input. */
            titan_array_set_stack(L, array, 1, -1);
            lua_settop(L, 1);
        }
        assert(encode_policy(L, graph) != LUA_OK);
        assert(strstr(lua_tostring(L, -1), diagnostics[kind]) != NULL);
        titan_transfer_free(graph);
        assert(allocations == 0);
        lua_close(L);
    }
}

int main(void) {
    test_policy_variants_and_source_retirement();
    test_policy_allocation_failures();
    test_custom_capture_and_policy_wrapper();
    test_custom_payload_cycles();
    test_invalid_policy_packets();
    test_reentrant_box_identity_roots();
    test_native_allocation_failures();
    test_source_retirement_and_aliases();
    test_binary_strings_and_provider_identity();
    test_rejected_graphs();
    puts("closure transfer runtime ok");
    return 0;
}
