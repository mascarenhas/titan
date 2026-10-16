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

static char outer_native, inner_native, leaf_native, detaching_native, function_tag;
static unsigned module_initializations;
static int reconstruction_budget = -1;
static void *fixture_symbols(const char *name);

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

int main(void) {
    test_reentrant_box_identity_roots();
    test_native_allocation_failures();
    test_source_retirement_and_aliases();
    test_binary_strings_and_provider_identity();
    test_rejected_graphs();
    puts("closure transfer runtime ok");
    return 0;
}
