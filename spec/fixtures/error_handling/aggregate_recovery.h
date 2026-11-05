#ifndef TITAN_AGGREGATE_RECOVERY_TEST_H
#define TITAN_AGGREGATE_RECOVERY_TEST_H
#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <titan/ffi.h>

typedef struct recovery_pair { int first, last; } recovery_pair;
typedef union recovery_cell { int count; double number; } recovery_cell;
typedef int recovery_row[2];
typedef struct recovery_holder { int items[3]; } recovery_holder;
typedef struct recovery_packet { int tag; int items[]; } recovery_packet;
typedef struct recovery_resource { unsigned char *allocation; size_t marker; } recovery_resource;

typedef enum recovery_code { RECOVERY_INITIAL = 1, RECOVERY_WRITTEN = 7 } recovery_code;
static int recovery_external_marker;
static void recovery_scalars_write(long double *number, recovery_code *code, void **pointer) {
    *number = 4.5L;
    *code = RECOVERY_WRITTEN;
    *pointer = &recovery_external_marker;
}

static unsigned char *recovery_live;
static int recovery_disposals;
static void recovery_acquire(recovery_resource *out) {
    assert(!recovery_live && !out->allocation);
    recovery_live = (unsigned char *)malloc(1);
    assert(recovery_live);
    *recovery_live = 37;
    out->allocation = recovery_live;
    out->marker = 37;
}
static int recovery_dispose(recovery_resource *out) {
    if (!out->allocation) return 0;
    assert(out->allocation == recovery_live && out->marker == 37);
    free(out->allocation);
    recovery_live = out->allocation = NULL;
    out->marker = 0;
    return ++recovery_disposals;
}
static void recovery_finish(void) { free(recovery_live); recovery_live = NULL; }
static void recovery_pair_write(recovery_pair *out) { out->first = 7; out->last = 11; }
static void recovery_cell_write(recovery_cell *out) { out->count = 19; }
static void recovery_array_write(int *out) { out[0] = 3; out[1] = 5; out[2] = 13; }
static void recovery_matrix_write(recovery_row *out) { out[0][1] = 17; out[1][0] = 23; }
static void recovery_array_error(lua_State *L, int *out) {
    recovery_array_write(out);
    luaL_error(L, "array written");
}
static void recovery_packet_error(lua_State *L, recovery_packet *out) {
    out->tag = 29;
    out->items[0] = 31;
    out->items[1] = 37;
    luaL_error(L, "flexible tail written");
}

typedef struct recovery_gc_object { int epoch, kind; } recovery_gc_object;
static int recovery_gc_epoch;
static int recovery_gc_finalized[3];
static int recovery_gc_during_close[3];
static int recovery_gc_closes;
static int recovery_gc_finally;
static int recovery_gc_finalize(lua_State *L) {
    recovery_gc_object *object = (recovery_gc_object *)lua_touserdata(L, 1);
    if (object->epoch == recovery_gc_epoch) ++recovery_gc_finalized[object->kind];
    return 0;
}
static void recovery_gc_push(lua_State *L, int kind) {
    recovery_gc_object *object = (recovery_gc_object *)lua_newuserdatauv(L, sizeof(*object), 0);
    object->epoch = recovery_gc_epoch;
    object->kind = kind;
    if (luaL_newmetatable(L, "titan.recovery.gc.object")) {
        lua_pushcfunction(L, recovery_gc_finalize);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);
}
static int recovery_gc_close(lua_State *L) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    recovery_gc_during_close[1] = recovery_gc_finalized[1];
    recovery_gc_during_close[2] = recovery_gc_finalized[2];
    ++recovery_gc_closes;
    return 0;
}
static void recovery_gc_prepare_close(lua_State *L) {
    luaL_checkstack(L, 8, "recovery GC close fixture");
    lua_newuserdatauv(L, 0, 0);
    if (luaL_newmetatable(L, "titan.recovery.gc.close")) {
        lua_pushcfunction(L, recovery_gc_close);
        lua_setfield(L, -2, "__close");
    }
    lua_setmetatable(L, -2);
    lua_toclose(L, -1);
}
static void recovery_gc_begin(lua_State *L) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    ++recovery_gc_epoch;
    recovery_gc_finalized[1] = recovery_gc_finalized[2] = 0;
    recovery_gc_during_close[1] = recovery_gc_during_close[2] = -1;
    recovery_gc_closes = recovery_gc_finally = 0;
}
static void recovery_gc_collect(lua_State *L) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
}
static int recovery_gc_finalized_count(int kind) { return recovery_gc_finalized[kind]; }
static void recovery_gc_old_value(lua_State *L, TValue *out) {
    recovery_gc_push(L, 1);
    setobj(L, out, s2v(L->top.p - 1));
    lua_pop(L, 1);
}
static void recovery_gc_old_pointer(lua_State *L, Udata **out) {
    recovery_gc_push(L, 1);
    *out = uvalue(s2v(L->top.p - 1));
    lua_pop(L, 1);
}
static void recovery_gc_store_value(lua_State *L, TValue *out, int fresh) {
    recovery_gc_prepare_close(L);
    if (fresh) {
        recovery_gc_push(L, 2);
        setobj(L, out, s2v(L->top.p - 1));
    } else setnilvalue(out);
    /* Keep a fresh object rooted through error handling. Lua's close protocol
     * truncates this root above the TBC cell before its __close forces GC. */
}
static void recovery_gc_store_pointer(lua_State *L, Udata **out, int fresh) {
    recovery_gc_prepare_close(L);
    if (fresh) {
        recovery_gc_push(L, 2);
        *out = uvalue(s2v(L->top.p - 1));
    } else *out = NULL;
}
static void recovery_gc_value_error(lua_State *L, TValue *out, int fresh) {
    recovery_gc_store_value(L, out, fresh);
    luaL_error(L, "GC value written");
}
static void recovery_gc_pointer_error(lua_State *L, Udata **out, int fresh) {
    recovery_gc_store_pointer(L, out, fresh);
    luaL_error(L, "GC pointer written");
}
static void recovery_gc_empty_error(lua_State *L) {
    recovery_gc_prepare_close(L);
    luaL_error(L, "before later declaration");
}
static void recovery_gc_note_finally(void) { ++recovery_gc_finally; }
static int recovery_gc_closed(void) { return recovery_gc_closes; }
static int recovery_gc_old_collected(void) { return recovery_gc_during_close[1]; }
static int recovery_gc_new_collected(void) { return recovery_gc_during_close[2]; }
static int recovery_gc_is_nil(const TValue *value) { return ttisnil(value); }
static int recovery_gc_value_kind(const TValue *value) {
    assert(ttisfulluserdata(value));
    return ((recovery_gc_object *)getudatamem(uvalue(value)))->kind;
}
static int recovery_gc_pointer_kind(Udata *value) {
    assert(value);
    return ((recovery_gc_object *)getudatamem(value))->kind;
}
#endif
