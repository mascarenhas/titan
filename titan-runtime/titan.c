#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
#include "lua.h"
#include "lauxlib.h"
#include "lapi.h"
#include "ldo.h"
#include "lfunc.h"
#include "lgc.h"
#include "lobject.h"
#include "llimits.h"
#include "lstate.h"
#include "ltable.h"
#include "titan.h"
#if defined(_WIN32)
#include "titan_winloader.h"
#endif

/*
** These assertions make the assumptions inherited from Lua's MAXASIZE
** definition explicit. They intentionally use C99-compatible negative-array
** diagnostics because Titan compiles generated/runtime C in C99 mode.
*/
typedef char titan_array_assert_matching_int_width[
    (l_numbits(unsigned int) == l_numbits(int)) ? 1 : -1];
typedef char titan_array_assert_capacity_fits_lua_integer[
    ((lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY <=
     (lua_Unsigned)LUA_MAXINTEGER) ? 1 : -1];
typedef char titan_array_assert_useful_capacity[
    (TITAN_ARRAY_MAX_CAPACITY >= 2u) ? 1 : -1];

const char *titan_publish_function_type_tag(lua_State *L,
                                            const char *registry_key,
                                            const char *candidate) {
    if (!lua_checkstack(L, 1))
        luaL_error(L, "stack overflow publishing Titan function-type tag");

    /*
    ** The type-specific string slot elects one canonical tag independently of
    ** module/provider load order. A later publisher recovers that pointer
    ** rather than publishing its own translation-unit-local candidate.
    */
    lua_getfield(L, LUA_REGISTRYINDEX, registry_key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_pushlightuserdata(L, (void *)candidate);
        lua_setfield(L, LUA_REGISTRYINDEX, registry_key);
        return candidate;
    }
    else {
        const char *canonical = (const char *)lua_touserdata(L, -1);
        lua_pop(L, 1);
        return canonical;
    }
}

static Table *titan_array_callback_metatable(lua_State *L, int index) {
    TValue value = lua_totvalue(L, lua_upvalueindex(index));
    if (!ttistable(&value))
        luaL_error(L, "invalid Titan array metatable");
    return hvalue(&value);
}

unsigned titan_array_growth(lua_State *L, lua_Unsigned index) {
    int clz = __builtin_clzll(index);
    unsigned capacity = (clz >= 33) ? (1u << (64 - clz)) : (TITAN_ARRAY_MAX_CAPACITY + 1u);
    if (TITAN_UNLIKELY(capacity > TITAN_ARRAY_MAX_CAPACITY))
        luaL_error(L, "array index too large");
    return capacity;
}

/* Implementation notes: doc/implementation/dense-arrays.md#authoritative-lenhint-and-resizing */
void titan_array_resize(lua_State *L, Table *backing,
                        lua_Unsigned capacity) {
    lua_Unsigned length;

    lua_assert(capacity <= TITAN_ARRAY_MAX_CAPACITY);
    lua_assert(capacity >= backing->asize);
    if (capacity == backing->asize)
        return;
    length = titan_array_length(backing);
    luaH_resizearray(L, backing, cast_uint(capacity));
    titan_array_set_length(backing, length);
}

lu_byte titan_array_get(Table *backing, lua_Integer index, TValue *result) {
    lua_Unsigned logical_index;
    lu_byte tag;

    if (index < 1) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    logical_index = l_castS2U(index);
    if (logical_index >= backing->asize) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    tag = *getArrTag(backing, cast_uint(logical_index));
    if (tagisempty(tag)) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    farr2val(backing, cast_uint(logical_index), tag, result);
    return tag;
}

void titan_array_set_stack(lua_State *L, Table *backing, lua_Integer index,
                           int value_index) {
    TValue value;
    lua_Unsigned logical_index;
    lua_Unsigned length;

    if (index < 1)
        luaL_error(L, "Titan array index must be positive");
    logical_index = l_castS2U(index);
    value = lua_totvalue(L, value_index);
    length = titan_array_length(backing);

    if (logical_index >= backing->asize) {
        if (ttisnil(&value))
            return;
        titan_array_resize(L, backing, titan_array_growth(L, logical_index));
        value = lua_totvalue(L, value_index);
    }

    obj2arr(backing, cast_uint(logical_index), &value);
    luaC_barrierback(L, obj2gco(backing), &value);

    if (ttisnil(&value)) {
        if (logical_index == length) {
            do {
                length--;
            } while (length > 0 &&
                     tagisempty(*getArrTag(backing, cast_uint(length))));
            titan_array_set_length(backing, length);
        }
    }
    else if (logical_index > length) {
        titan_array_set_length(backing, logical_index);
    }
}

static int titan_array_lua_index(lua_State *L) {
    Table *metatable = titan_array_callback_metatable(L, 1);
    Table *other_metatable = titan_array_callback_metatable(L, 2);
    TValue receiver = lua_totvalue(L, 1);
    Table *backing = titan_array_require_backing(&receiver);
    lua_Integer index;
    TValue result = {0};

    if (lua_type(L, 2) != LUA_TNUMBER)
        return luaL_error(L, "Titan array index must be an integer");
    {
        int isinteger;
        index = lua_tointegerx(L, 2, &isinteger);
        if (!isinteger)
            return luaL_error(L, "Titan array index must be an integer");
    }
    titan_array_get(backing, index, &result);
    if (ttistable(&result)) {
        Udata *proxy = titan_array_try_proxy_either(
            hvalue(&result), metatable, other_metatable);
        if (proxy != NULL)
            setuvalue(L, &result, proxy);
    }
    lua_pushtvalue(L, result);
    return 1;
}

/* Implementation notes: doc/implementation/dense-arrays.md#array-writes */
static int titan_array_lua_newindex(lua_State *L) {
    TValue receiver = lua_totvalue(L, 1);
    Table *backing = titan_array_require_backing(&receiver);
    Udata *proxy = uvalue(&receiver);
    lua_Integer index;
    lua_Unsigned logical_index;
    int isinteger;

    if (lua_type(L, 2) != LUA_TNUMBER)
        return luaL_error(L, "Titan array index must be an integer");
    index = lua_tointegerx(L, 2, &isinteger);
    if (!isinteger)
        return luaL_error(L, "Titan array index must be an integer");
    if (index < 1)
        return luaL_error(L, "Titan array index must be positive");

    if (lua_isnil(L, 3)) {
        titan_array_set_stack(L, backing, index, 3);
        return 0;
    }

    logical_index = l_castS2U(index);
    if (logical_index >= backing->asize)
        cast_void(titan_array_growth(L, logical_index));

    if (!lua_checkstack(L, 2))
        return luaL_error(L, "stack overflow writing Titan array");
    lua_pushtvalue(L, proxy->uv[1].uv);
    lua_pushvalue(L, 3);
    lua_call(L, 1, 1);

    titan_array_set_stack(L, backing, index, -1);
    lua_pop(L, 1);
    return 0;
}

static int titan_array_lua_len(lua_State *L) {
    TValue receiver = lua_totvalue(L, 1);
    Table *backing = titan_array_require_backing(&receiver);
    lua_pushinteger(L, cast_Integer(titan_array_length(backing)));
    return 1;
}

#define TITAN_ARRAY_METATABLE_PAIR "Titan array metatable pair"

static void titan_array_set_callback(lua_State *L, int metatable_index,
                                     const char *name,
                                     lua_CFunction callback,
                                     int self_index, int other_index) {
    metatable_index = lua_absindex(L, metatable_index);
    self_index = lua_absindex(L, self_index);
    other_index = lua_absindex(L, other_index);
    lua_pushstring(L, name);
    lua_pushvalue(L, self_index);
    lua_pushvalue(L, other_index);
    lua_pushcclosure(L, callback, 2);
    lua_rawset(L, metatable_index);
}

static void titan_array_initialize_metatable(lua_State *L,
                                             int metatable_index,
                                             const char *name,
                                             int self_index,
                                             int other_index,
                                             int mutable) {
    metatable_index = lua_absindex(L, metatable_index);
    lua_pushinteger(L, mutable ? TITAN_ARRAY : TITAN_CONST_ARRAY);
    lua_rawsetp(L, metatable_index, TITAN_BRAND);
    lua_pushstring(L, name);
    lua_setfield(L, metatable_index, "__name");
    lua_pushstring(L, name);
    lua_setfield(L, metatable_index, "__metatable");
    titan_array_set_callback(L, metatable_index, "__index",
                             titan_array_lua_index,
                             self_index, other_index);
    if (mutable)
        titan_array_set_callback(L, metatable_index, "__newindex",
                                 titan_array_lua_newindex,
                                 self_index, other_index);
    titan_array_set_callback(L, metatable_index, "__len",
                             titan_array_lua_len,
                             self_index, other_index);
}

static void titan_array_publish_registry_entry(lua_State *L,
                                               const char *name,
                                               Table *metatable) {
    TValue value;

    lua_getfield(L, LUA_REGISTRYINDEX, name);
    value = lua_totvalue(L, -1);
    if (ttisnil(&value)) {
        lua_pop(L, 1);
        sethvalue(L, &value, metatable);
        lua_pushtvalue(L, value);
        lua_setfield(L, LUA_REGISTRYINDEX, name);
    }
    else {
        if (!ttistable(&value) || hvalue(&value) != metatable)
            luaL_error(L, "invalid Titan array metatable registry entry");
        lua_pop(L, 1);
    }
}

/* Implementation notes: doc/implementation/const-values.md#runtime-array-pair */
void titan_array_metatables(lua_State *L, Table **mutable_out,
                            Table **const_out) {
    int base;
    Table *mutable_metatable;
    Table *const_metatable;
    TValue value;

    if (mutable_out == NULL || const_out == NULL)
        luaL_error(L, "invalid Titan array metatable output");
    if (!lua_checkstack(L, 8))
        luaL_error(L, "stack overflow creating Titan array metatables");
    base = lua_gettop(L);

    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE_PAIR);
    value = lua_totvalue(L, -1);
    if (ttisnil(&value)) {
        int mutable_index;
        int const_index;
        int pair_index;

        lua_pop(L, 1);
        lua_getfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
        if (!lua_isnil(L, -1))
            luaL_error(L, "invalid Titan array metatable registry entry");
        lua_pop(L, 1);
        lua_getfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
        if (!lua_isnil(L, -1))
            luaL_error(L, "invalid Titan array metatable registry entry");
        lua_pop(L, 1);

        lua_newtable(L);
        mutable_index = lua_gettop(L);
        lua_newtable(L);
        const_index = lua_gettop(L);
        titan_array_initialize_metatable(
            L, mutable_index, TITAN_ARRAY_METATABLE,
            mutable_index, const_index, 1);
        titan_array_initialize_metatable(
            L, const_index, TITAN_CONST_ARRAY_METATABLE,
            const_index, mutable_index, 0);

        value = lua_totvalue(L, mutable_index);
        lua_assert(ttistable(&value));
        mutable_metatable = hvalue(&value);
        value = lua_totvalue(L, const_index);
        lua_assert(ttistable(&value));
        const_metatable = hvalue(&value);
        lua_assert(mutable_metatable != const_metatable);

        /*
        ** The single pair table is the canonical publication point. Both
        ** callback families already close over the complete pair, so no
        ** callback can observe one identity while the other is incomplete.
        ** The traditional named entries are projections retained for normal
        ** luaL_getmetatable users and are repaired from the canonical pair if
        ** an allocation interrupted publication after this point.
        */
        lua_newtable(L);
        pair_index = lua_gettop(L);
        lua_pushvalue(L, mutable_index);
        lua_rawseti(L, pair_index, 1);
        lua_pushvalue(L, const_index);
        lua_rawseti(L, pair_index, 2);
        lua_pushvalue(L, pair_index);
        lua_setfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE_PAIR);
        titan_array_publish_registry_entry(
            L, TITAN_ARRAY_METATABLE, mutable_metatable);
        titan_array_publish_registry_entry(
            L, TITAN_CONST_ARRAY_METATABLE, const_metatable);
    }
    else {
        int pair_index;

        if (!ttistable(&value))
            luaL_error(L, "invalid Titan array metatable pair registry entry");
        pair_index = lua_gettop(L);
        lua_rawgeti(L, pair_index, 1);
        value = lua_totvalue(L, -1);
        if (!ttistable(&value))
            luaL_error(L, "invalid Titan array metatable pair registry entry");
        mutable_metatable = hvalue(&value);
        lua_pop(L, 1);
        lua_rawgeti(L, pair_index, 2);
        value = lua_totvalue(L, -1);
        if (!ttistable(&value))
            luaL_error(L, "invalid Titan array metatable pair registry entry");
        const_metatable = hvalue(&value);
        lua_pop(L, 1);
        if (mutable_metatable == const_metatable)
            luaL_error(L, "invalid Titan array metatable pair registry entry");
        titan_array_publish_registry_entry(
            L, TITAN_ARRAY_METATABLE, mutable_metatable);
        titan_array_publish_registry_entry(
            L, TITAN_CONST_ARRAY_METATABLE, const_metatable);
    }

    lua_settop(L, base);
    *mutable_out = mutable_metatable;
    *const_out = const_metatable;
}

void titan_array_cached_metatables(lua_State *L, Table **mutable_out,
                                   Table **const_out) {
    TValue pair_value;
    TValue mutable_value;
    TValue const_value;
    TString *registry_key;
    Table *pair;
    lu_byte tag;

    lua_assert(mutable_out != NULL && const_out != NULL);
    lua_assert(ttistable(&G(L)->l_registry));
    registry_key = luaS_newliteral(L, TITAN_ARRAY_METATABLE_PAIR);
    tag = luaH_getstr(
        hvalue(&G(L)->l_registry), registry_key, &pair_value);
    lua_assert(!tagisempty(tag) && ttistable(&pair_value));
    pair = hvalue(&pair_value);
    tag = luaH_getint(pair, 1, &mutable_value);
    lua_assert(!tagisempty(tag) && ttistable(&mutable_value));
    tag = luaH_getint(pair, 2, &const_value);
    lua_assert(!tagisempty(tag) && ttistable(&const_value));
    lua_assert(hvalue(&mutable_value) != hvalue(&const_value));
    (void)tag;
    *mutable_out = hvalue(&mutable_value);
    *const_out = hvalue(&const_value);
}

Table *titan_array_metatable(lua_State *L) {
    Table *mutable_metatable;
    Table *const_metatable;
    titan_array_metatables(L, &mutable_metatable, &const_metatable);
    cast_void(const_metatable);
    return mutable_metatable;
}

/* Implementation notes: doc/implementation/dense-arrays.md#runtime-construction */
Table *titan_array_new_impl(lua_State *L, Table *metatable,
                            lua_Unsigned capacity,
                            const TValue *writer, int mutable,
                            StkId result) {
    Table *backing;
    Udata *proxy;
    TValue proxy_value;
    TValue writer_value = {0};

    lua_assert(metatable != NULL);
    lua_assert(result != NULL);
    if (mutable) {
        lua_assert(writer != NULL && writer != s2v(result));
        writer_value = *writer;
        lua_assert(ttisCclosure(&writer_value));
    }
    else {
        lua_assert(writer == NULL);
        setnilvalue(&writer_value);
    }
    lua_assert(capacity <= TITAN_ARRAY_MAX_CAPACITY);

    backing = luaH_new(L);
    sethvalue2s(L, result, backing);
    /* Physical array capacity is capacity + 1 (slot 0 for proxy), hash size is 0. */
    luaH_resize(L, backing, cast_uint(capacity + 1u), 0);
    titan_array_set_length(backing, 0);

    proxy = luaS_newudata(L, 0, 2);
    proxy->metatable = metatable;
    sethvalue(L, &proxy->uv[0].uv, backing);
    setobj(L, &proxy->uv[1].uv, &writer_value);
    luaC_objbarrier(L, proxy, metatable);
    luaC_checkfinalizer(L, obj2gco(proxy), metatable);
    luaC_barrierback(L, obj2gco(proxy), &proxy->uv[0].uv);
    if (mutable)
        luaC_barrierback(L, obj2gco(proxy), &proxy->uv[1].uv);

    setuvalue(L, &proxy_value, proxy);
    obj2arr(backing, 0, &proxy_value);
    luaC_barrierback(L, obj2gco(backing), &proxy_value);

    luaC_checkGC(L);
    lua_assert(titan_array_try_proxy(backing, metatable) == proxy);
    lua_assert(mutable ? ttisCclosure(&proxy->uv[1].uv)
                       : ttisnil(&proxy->uv[1].uv));
    return backing;
}

/* Implementation notes: doc/implementation/dense-arrays.md#mutable-to-const-lowering */
Table *titan_array_shallow_copy(lua_State *L, Table *source,
                                Table *mutable_metatable,
                                Table *const_metatable,
                                StkId result) {
    lua_Unsigned length;
    lua_Unsigned i;
    Table *target;
    TValue value;

    lua_assert(mutable_metatable != NULL && const_metatable != NULL);
    lua_assert(mutable_metatable != const_metatable);
    lua_assert(result != NULL);
    lua_assert(titan_array_try_proxy(source, mutable_metatable) != NULL);
    length = titan_array_length(source);
    /*
    ** Preserve the source's physical allocation as well as its logical
    ** length. Copying only the logical prefix below still leaves any spare
    ** capacity empty. Note source->asize includes slot 0 (capacity + 1).
    */
    target = titan_const_array_new(L, const_metatable,
                                   (lua_Unsigned)(source->asize - 1u), result);

    for (i = 1; i <= length; i++) {
        lu_byte tag = *getArrTag(source, cast_uint(i));
        if (!tagisempty(tag)) {
            farr2val(source, cast_uint(i), tag, &value);
            obj2arr(target, cast_uint(i), &value);
            luaC_barrierback(L, obj2gco(target), &value);
        }
    }
    titan_array_set_length(target, length);
    lua_assert(target->asize == source->asize);
    lua_assert(titan_array_try_proxy(target, const_metatable) != NULL);
    return target;
}

Table *titan_array_freeze(lua_State *L, Table *backing,
                          Table *mutable_metatable,
                          Table *const_metatable) {
    Udata *proxy;

    lua_assert(mutable_metatable != NULL && const_metatable != NULL);
    lua_assert(mutable_metatable != const_metatable);
    lua_assert(backing != NULL && backing->asize > 0);
    proxy = gco2u(getArrVal(backing, 0)->gc);
    lua_assert(proxy->metatable == mutable_metatable);
    lua_assert(ttisCclosure(&proxy->uv[1].uv));

    proxy->metatable = const_metatable;
    luaC_objbarrier(L, proxy, const_metatable);
    luaC_checkfinalizer(L, obj2gco(proxy), const_metatable);
    setnilvalue(&proxy->uv[1].uv);

    lua_assert(titan_array_try_proxy(backing, mutable_metatable) == NULL);
    lua_assert(titan_array_try_proxy(backing, const_metatable) == proxy);
    lua_assert(ttisnil(&proxy->uv[1].uv));
    return backing;
}

static void titan_bt_addframe_lstring(luaL_Buffer *buf, int *wrote_any,
                                      const char *text, size_t len) {
    if (*wrote_any) luaL_addchar(buf, '\n');
    luaL_addlstring(buf, text, len);
    *wrote_any = 1;
}

static void titan_bt_addframe(luaL_Buffer *buf, int *wrote_any,
                              const char *text) {
    titan_bt_addframe_lstring(buf, wrote_any, text, strlen(text));
}

/* Native-stack capture backend. libbacktrace symbolizes PCs across every
** loaded provider to a #line-attributed .titan file/line (and recovers inlined
** frames); the old execinfo path is kept as a no-DWARF fallback for platforms
** without libbacktrace (e.g. musl/Alpine). Define TITAN_NO_LIBBACKTRACE to
** force the fallback. */
#if !defined(TITAN_NO_LIBBACKTRACE)
#include "backtrace.h"
#define TITAN_HAVE_LIBBACKTRACE 1
#elif !defined(_WIN32)
#include <execinfo.h>
#endif

#ifndef TITAN_HAVE_LIBBACKTRACE
/* Convert a luaL_traceback-style string into Titan's raw traceback value:
** remove the leading "stack traceback:" line and strip the presentation tab
** from the beginning of each frame line. */
static void titan_add_raw_lua_trace(luaL_Buffer *buf, int *wrote_any,
                                    const char *trace) {
    const char *p = trace;
    if (p == NULL) return;
    if (strncmp(p, "stack traceback:", 16) == 0) {
        p += 16;
        if (*p == '\n') p++;
    }
    while (*p != '\0') {
        const char *e;
        size_t len;
        if (*p == '\t') p++;
        e = strchr(p, '\n');
        len = e ? (size_t)(e - p) : strlen(p);
        if (len > 0) {
            titan_bt_addframe_lstring(buf, wrote_any, p, len);
        }
        if (e == NULL) break;
        p = e + 1;
    }
}
#endif

#ifdef TITAN_HAVE_LIBBACKTRACE
/* libbacktrace snapshots the set of loaded objects ONCE, on the first
** symbolization, and never re-scans. Windows uses a PE module snapshot with
** loader notifications disabled; Unix caches the dl_iterate_phdr result. A
** module loaded after that snapshot would have no symbols, so provider loads
** (loadlib() and the Titan searcher in titan_path.c) and generated luaopen_*
** functions invalidate this cached state after successful
** loads; the next capture lazily re-creates it and re-snapshots. The state is
** never freed (a small, bounded leak), never recreated per-error. Keep the
** pointer in the Lua registry so every titan.o image in that state shares the
** cache without relying on mutable per-DSO C globals. */
typedef struct {
    struct backtrace_state *state;
} titan_bt_cache;

static void titan_bt_error(void *data, const char *msg, int errnum) {
    (void)data; (void)msg; (void)errnum;  /* swallow: a missing frame is fine */
}

static struct backtrace_state *titan_backtrace_state(lua_State *L) {
    int top = lua_gettop(L);
    struct backtrace_state *state = NULL;
    titan_bt_cache *cache;

    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_type(L, -1) == LUA_TUSERDATA &&
            lua_rawlen(L, -1) == sizeof(titan_bt_cache)) {
        cache = (titan_bt_cache *)lua_touserdata(L, -1);
        state = cache->state;
    }
    lua_settop(L, top);
    if (state != NULL) return state;

    state = backtrace_create_state(NULL, 1, titan_bt_error, NULL);
    if (state == NULL) return NULL;

    cache = (titan_bt_cache *)lua_newuserdatauv(
        L, sizeof(titan_bt_cache), 0);
    cache->state = state;
    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_settop(L, top);
    return state;
}

/* Reset after a slow-path provider load or a Lua require that mapped a provider.
** Every titan.o copy clears the same per-state registry slot. The next capture
** recreates it with the now-complete process image snapshot. */
/* Implementation notes: doc/implementation/error-handling.md#backtrace-state-invalidation */
void titan_invalidate_backtrace_state(lua_State *L) {
    int top = lua_gettop(L);
    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_settop(L, top);
}

static const char *titan_basename(const char *path) {
    const char *slash = path ? strrchr(path, '/') : NULL;
#if defined(_WIN32)
    const char *backslash = path ? strrchr(path, '\\') : NULL;
    if (backslash != NULL && (slash == NULL || backslash > slash))
        slash = backslash;
#endif
    return slash ? slash + 1 : path;
}

/* TITAN_ENTRY_TAG must match coder.lua's: every generated Lua entry-wrapper C
** symbol carries this substring, marking a Lua->Titan boundary in the native
** stack. (The native functions a wrapper invokes are *_titan / *_titanstatic /
** *_titanmethod / *_boundmethod and do NOT contain it.) */
#define TITAN_ENTRY_TAG "titanentry"

/* The maintained list of Lua 5.5 source filenames (core + libraries). A native
** frame whose DWARF filename ends in one of these is a Lua interpreter or
** standard-library frame: it is DROPPED from the native side, because the Lua
** activations it ran are already enumerated, with names, from the CallInfo
** chain (a pure-Lua frame as `src:line:`, a Lua C-function as `[C]:`). Dropping
** the *library* files specifically prevents double-counting a Lua C-function
** that would otherwise appear both here and as its CallInfo `[C]` frame. */
static const char *const titan_lua_sources[] = {
    /* core */
    "lvm.c", "ldo.c", "lapi.c", "lgc.c", "ldebug.c", "lstate.c", "lfunc.c",
    "ltable.c", "lobject.c", "lstring.c", "ltm.c", "lmem.c", "lzio.c",
    "lctype.c", "lopcodes.c", "lcode.c", "lparser.c", "llex.c", "lundump.c",
    "ldump.c",
    /* libraries */
    "lauxlib.c", "lbaselib.c", "lstrlib.c", "ltablib.c", "lmathlib.c",
    "liolib.c", "loslib.c", "lcorolib.c", "ldblib.c", "lutf8lib.c", "loadlib.c",
    "linit.c",
    NULL
};

static int titan_is_lua_source(const char *base) {
    int i;
    if (base == NULL) return 0;
    for (i = 0; titan_lua_sources[i] != NULL; i++) {
        if (strcmp(base, titan_lua_sources[i]) == 0) return 1;
    }
    return 0;
}

/* One captured native frame that survived filtering: either a Titan native
** function (a `.titan`-attributed frame) or a Titan entry-wrapper boundary
** (`is_entry`). The interpreter, libraries, runtime and unsymbolized frames are
** dropped at capture time and never reach this array. The raw DWARF base
** filename / line / symbol are kept (not preformatted) so the merge can look the
** symbol up in registry[TITAN_NAMES_KEY] and substitute the qualified Titan
** source name — which the collect callback cannot do (it has no lua_State). */
typedef struct {
    char base[256];   /* DWARF base filename, e.g. "test.titan" */
    char function[256]; /* the (mangled) C symbol name */
    int lineno;       /* DWARF line of the current execution point */
    int is_entry;     /* nonzero: this frame is an entry-wrapper boundary */
} titan_native_frame;

#define TITAN_MAX_NATIVE 512

typedef struct {
    titan_native_frame *frames;
    int n;
    int cap;
} titan_native_stack;

/* Implementation notes: doc/implementation/error-handling.md#libbacktrace-and-frame-merging */
static int titan_bt_collect_cb(void *data, uintptr_t pc, const char *filename,
                               int lineno, const char *function) {
    titan_native_stack *st = (titan_native_stack *)data;
    const char *base;
    int is_titan, is_entry;
    (void)pc;
    if (st->n >= st->cap) return 0;             /* full: stop collecting */
    if (filename == NULL) return 0;             /* unsymbolized: drop */
    base = titan_basename(filename);
    if (strstr(filename, "titan-runtime/")
#if defined(_WIN32)
            || strstr(filename, "titan-runtime\\")
#endif
            ) return 0;  /* runtime: drop */
    if (titan_is_lua_source(base)) return 0;    /* Lua core/library: drop */
    is_entry = (function != NULL && strstr(function, TITAN_ENTRY_TAG) != NULL);
    /* A surviving frame is a Titan frame iff its source is a .titan chunk
    ** (post-#line) or it is recognizably an entry wrapper by symbol name. */
    is_titan = is_entry;
    if (!is_titan) {
        size_t blen = base ? strlen(base) : 0;
        if (blen >= 6 && strcmp(base + blen - 6, ".titan") == 0) is_titan = 1;
    }
    if (!is_titan) return 0;                     /* not a Titan frame: drop */
    {
        titan_native_frame *f = &st->frames[st->n++];
        f->is_entry = is_entry;
        f->lineno = lineno;
        snprintf(f->base, sizeof(f->base), "%s", base ? base : "?");
        snprintf(f->function, sizeof(f->function), "%s",
                 function ? function : "?");
    }
    return 0;
}

/* Capture the filtered native stack (Titan frames + entry-wrapper boundaries
** only) into `st`, innermost->outer. Returns 0 if libbacktrace is unavailable. */
static int titan_capture_native(lua_State *L, titan_native_stack *st) {
    struct backtrace_state *state = titan_backtrace_state(L);
    if (state == NULL) return 0;
    /* skip=1: drop errorhandler's own frame. */
    backtrace_full(state, 1, titan_bt_collect_cb, titan_bt_error, st);
    return 1;
}

/* A best-effort function name for a CallInfo, mirroring luaL_traceback's
** pushfuncname but without the global-name search (which would manipulate the
** Lua stack while a luaL_Buffer is open at the top). Writes into `out` and
** returns it; never pushes to the stack. */
static const char *titan_funcname(lua_Debug *ar, char *out, size_t outsz) {
    if (ar->namewhat != NULL && ar->namewhat[0] != '\0' && ar->name != NULL) {
        snprintf(out, outsz, "%s '%s'", ar->namewhat, ar->name);
    } else if (ar->what != NULL && ar->what[0] == 'm') {
        snprintf(out, outsz, "main chunk");
    } else if (ar->what != NULL && ar->what[0] != 'C') {
        snprintf(out, outsz, "function <%s:%d>", ar->short_src,
                 ar->linedefined);
    } else {
        snprintf(out, outsz, "?");
    }
    return out;
}

/* Look up `sym` (a native frame's mangled C symbol) in registry[TITAN_NAMES_KEY]
** and copy the qualified Titan source name into `out`, returning it; if the
** sub-table or the key is absent, copy the raw `sym` and return that (fallback).
** Leaves the Lua stack exactly as found (the merge runs with a luaL_Buffer open
** at the top, so this MUST be stack-neutral). */
static const char *titan_qualified_name(lua_State *L, const char *sym,
                                        char *out, size_t outsz) {
    int top = lua_gettop(L);
    const char *qn = sym;
    lua_pushliteral(L, TITAN_NAMES_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);          /* names sub-table or nil */
    if (lua_istable(L, -1)) {
        lua_pushstring(L, sym);
        lua_rawget(L, -2);                      /* names[sym] or nil */
        if (lua_type(L, -1) == LUA_TSTRING) {
            qn = lua_tostring(L, -1);
        }
    }
    snprintf(out, outsz, "%s", qn ? qn : "?");
    lua_settop(L, top);                         /* restore: stack-neutral */
    return out;
}

/* Format one surviving native Titan FUNCTION frame (never an entry-wrapper
** boundary — those are suppressed by the caller) as a trace line, substituting
** the qualified Titan name for the mangled C symbol. */
static void titan_format_native(lua_State *L, char *line, size_t linesz,
                                const titan_native_frame *f) {
    char nm[256];
    titan_qualified_name(L, f->function, nm, sizeof(nm));
    snprintf(line, linesz, "%s:%d: in %s", f->base, f->lineno, nm);
}

typedef struct {
    int is_entry;
} titan_entry_probe;

static void titan_entry_syminfo_cb(void *data, uintptr_t pc,
                                   const char *symname, uintptr_t symval,
                                   uintptr_t symsize) {
    titan_entry_probe *probe = (titan_entry_probe *)data;
    (void)pc; (void)symval; (void)symsize;
    if (symname != NULL && strstr(symname, TITAN_ENTRY_TAG) != NULL) {
        probe->is_entry = 1;
    }
}

static int titan_cfunction_is_entry(lua_State *L, lua_CFunction fn) {
    struct backtrace_state *state;
    titan_entry_probe probe;
    probe.is_entry = 0;
    state = titan_backtrace_state(L);
    if (state == NULL) return 0;
    backtrace_syminfo(state,
                      (uintptr_t)titan_cast_func(void *, fn),
                      titan_entry_syminfo_cb, titan_bt_error, &probe);
    return probe.is_entry;
}

/* Consume the next native Titan run up to and including its entry-wrapper
** sentinel. Entry-wrapper frames are boundary markers only (consumed, never
** emitted); native function frames are appended in order. Returns nonzero if an
** entry sentinel was consumed, proving this run corresponds to a Lua-visible
** Titan entry-wrapper CallInfo. */
static int titan_drain_native_run(lua_State *L, luaL_Buffer *buf,
                                  titan_native_stack *st, int *ni,
                                  int *wrote_any) {
    int consumed_entry = 0;
    while (*ni < st->n) {
        int was_entry = st->frames[*ni].is_entry;
        if (!was_entry) {
            char line[768];
            titan_format_native(L, line, sizeof(line), &st->frames[*ni]);
            titan_bt_addframe(buf, wrote_any, line);
        } else {
            consumed_entry = 1;
        }
        (*ni)++;
        if (was_entry) break;
    }
    return consumed_entry;
}

/* Build ONE intermingled, innermost->outer trace mixing pure-Lua and Titan
** frames in call order. The CallInfo chain is the backbone: it
** enumerates every Lua activation (so a single native luaV_execute correctly
** expands into the multiple Lua frames it ran). The native libbacktrace stack
** supplies only the Titan native frames, spliced in at the entry-wrapper
** boundaries.
**
** Alignment: walk both stacks innermost->outer in lockstep. Each native Titan
** run ends at an entry-wrapper sentinel. The deepest (innermost) run is drained
** before the first CallInfo so the error site leads the trace; the very next
** Titan entry-wrapper CallInfo is then suppressed as already represented. For
** later C-level CallInfos, we first identify whether the C function really is a
** generated Titan entry wrapper (by symbolizing its lua_CFunction pointer and
** looking for TITAN_ENTRY_TAG). Genuine Lua C-functions are emitted as `[C]`;
** Titan entry wrappers drain exactly one native run and are themselves hidden.
** Pure-Lua CallInfo frames are emitted directly with src:line:in name.
**
** Trampoline collapse: each logical Titan call lands TWO native frames — the
** generated entry-wrapper (sentinel `titanentry`) and the native function it
** invokes. The entry-wrapper is a BOUNDARY MARKER ONLY: it still delimits a
** native run in the splice (`is_entry` terminates a drain), but it is NEVER
** emitted as a visible frame. Only the native function frame is shown (it
** carries the current execution line), so each Lua->Titan / method / closure
** call becomes a SINGLE Titan frame. Each emitted native frame's mangled C
** symbol is replaced by its qualified Titan source name from
** registry[TITAN_NAMES_KEY] (titan_format_native), falling back to the raw
** symbol if absent.
*/
static void titan_push_unified_trace(lua_State *L, luaL_Buffer *buf) {
    titan_native_frame frames[TITAN_MAX_NATIVE];
    titan_native_stack st;
    int ni = 0;          /* next un-emitted native frame index */
    int wrote_any = 0;
    int suppress_next_entry = 0;
    int level = 1;       /* skip errorhandler's own CallInfo (level 0) */
    lua_Debug ar;

    st.frames = frames;
    st.n = 0;
    st.cap = TITAN_MAX_NATIVE;
    titan_capture_native(L, &st);

    /* Drain the deepest native Titan run (the error site) before any CallInfo
    ** so the innermost Titan frames lead. Entry-wrapper frames are boundary
    ** markers only (consumed, never emitted); only native functions are shown. */
    suppress_next_entry =
        titan_drain_native_run(L, buf, &st, &ni, &wrote_any);

    while (lua_getstack(L, level++, &ar)) {
        lua_CFunction cfunc = NULL;
        int is_titan_entry = 0;
        lua_getinfo(L, "Slntf", &ar);           /* pushes function */
        if (ar.what != NULL && ar.what[0] == 'C') {
            cfunc = lua_tocfunction(L, -1);
            is_titan_entry = (cfunc != NULL && titan_cfunction_is_entry(L, cfunc));
        }
        lua_pop(L, 1);                          /* pop function from "f" */
        if (ar.what != NULL && ar.what[0] == 'C') {
            if (is_titan_entry) {
                if (suppress_next_entry) {
                    suppress_next_entry = 0;    /* deepest run already drained */
                } else if (ni < st.n) {
                    titan_drain_native_run(L, buf, &st, &ni, &wrote_any);
                }
                /* entry-wrapper CallInfo is a boundary marker only */
            } else {
                char line[512], nm[256];
                snprintf(line, sizeof(line), "%s: in %s",
                         ar.short_src, titan_funcname(&ar, nm, sizeof(nm)));
                titan_bt_addframe(buf, &wrote_any, line);
            }
        } else {
            /* A pure-Lua activation: src:line: in name. */
            char line[512], nm[256];
            const char *fn = titan_funcname(&ar, nm, sizeof(nm));
            if (ar.currentline > 0) {
                snprintf(line, sizeof(line), "%s:%d: in %s",
                         ar.short_src, ar.currentline, fn);
            } else {
                snprintf(line, sizeof(line), "%s: in %s",
                         ar.short_src, fn);
            }
            titan_bt_addframe(buf, &wrote_any, line);
        }
        if (ar.istailcall) {
            titan_bt_addframe(buf, &wrote_any, "(...tail calls...)");
        }
    }

    /* Defensive: any native Titan frames the CallInfo walk did not consume
    ** (e.g. native depth exceeding the Lua-visible boundaries) still appear.
    ** Entry-wrapper boundary markers remain suppressed. */
    while (ni < st.n) {
        if (!frames[ni].is_entry) {
            char line[768];
            titan_format_native(L, line, sizeof(line), &frames[ni]);
            titan_bt_addframe(buf, &wrote_any, line);
        }
        ni++;
    }
}
#else
void titan_invalidate_backtrace_state(lua_State *L) {
    (void)L;  /* no cached state to reset */
}
#endif

void *loadsym (lua_State *L, void *lib, const char *sym) {
#if defined(_WIN32)
    void *f;
    if (lib == NULL) luaL_error(L, "Windows Titan symbol lookup requires an explicit provider");
    f = titan_cast_func(void *, GetProcAddress((HMODULE)lib, sym));
    if (f == NULL) {
        titan_win_loader_error(L, "cannot resolve symbol", sym, GetLastError());
        lua_error(L);
    }
    return f;
#else
    void *f = dlsym(lib, sym);
    if(f == NULL) luaL_error(L, dlerror());
    return f;
#endif
}

void *loadglobalsym (lua_State *L, const char *sym) {
#if defined(_WIN32)
    luaL_error(L, "Windows Titan cannot resolve global native symbol '%s'; "
        "use the canonical module provider", sym);
    return NULL;
#else
    void *f;
    const char *err;
    dlerror();  /* clear stale error; a NULL symbol value can be valid */
    f = dlsym(RTLD_DEFAULT, sym);
    err = dlerror();
    if(err != NULL) luaL_error(L, "%s", err);
    return f;
#endif
}

static void *titan_find_module_symbol(TitanModuleProvider provider,
                                      const char *sym, const char **error) {
    void *raw;
    *error = NULL;
    if (provider.symbols != NULL) {
        raw = provider.symbols(sym);
        if (raw == NULL) *error = "symbol not found in canonical module";
        return raw;
    }
    if (provider.handle == NULL) {
        *error = "module provider is unavailable";
        return NULL;
    }
#if defined(_WIN32)
    raw = titan_cast_func(void *, GetProcAddress((HMODULE)provider.handle, sym));
    if (raw == NULL) *error = "export not found in Windows provider";
#else
    dlerror();
    raw = dlsym(provider.handle, sym);
    if (raw == NULL) *error = dlerror();
#endif
    return raw;
}

void *titan_module_symbol(lua_State *L, TitanModuleProvider provider,
                          const char *sym) {
    const char *error;
    void *raw = titan_find_module_symbol(provider, sym, &error);
    if (raw == NULL)
        luaL_error(L, "Titan module provider is missing symbol '%s': %s",
            sym, error ? error : "symbol not found");
    return raw;
}

void titan_check_abi(lua_State *L, void *lib, const char *sym,
                     const char *file) {
#if defined(_WIN32)
    TitanModuleProvider provider = { lib, NULL };
    titan_check_module_abi(L, provider, sym, file);
#else
    void *raw;
    const char *error;
    dlerror();
    raw = dlsym(lib != NULL ? lib : RTLD_DEFAULT, sym);
    error = raw == NULL ? dlerror() : NULL;
    titan_check_abi_entry(L, raw, sym, file, error);
#endif
}

void titan_check_module_abi(lua_State *L, TitanModuleProvider provider,
                            const char *sym, const char *file) {
#if defined(_WIN32)
    int top = lua_gettop(L);
    const char *error;
    const char *query;
    void *raw;
    luaL_checkstack(L, 1, "checking the Windows Titan ABI");
    query = lua_pushfstring(L, "%s_value", sym);
    raw = titan_find_module_symbol(provider, query, &error);
    titan_check_abi_entry(L, raw, query, file, error);
    lua_settop(L, top);
#else
    const char *error;
    void *raw = titan_find_module_symbol(provider, sym, &error);
    titan_check_abi_entry(L, raw, sym, file, error);
#endif
}

/* The generated verifier uses only these three primitives. Do not resolve
** them through mutable Lua globals: ordinary Lua code may replace error/next
** without changing the checks needed before entering native Titan code. */
static int titan_compatibility_type(lua_State *L) {
    lua_pushstring(L, lua_typename(L, lua_type(L, 1)));
    return 1;
}

static int titan_compatibility_next(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_settop(L, 2);
    if (lua_next(L, 1)) return 2;
    lua_pushnil(L);
    return 1;
}

static int titan_compatibility_error(lua_State *L) {
    lua_settop(L, 1);
    return lua_error(L);
}

static void titan_load_compatibility_chunk(lua_State *L, const char *source,
                                          size_t size, const char *name) {
    if (luaL_loadbufferx(L, source, size, name, "t") != LUA_OK)
        lua_error(L);
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, titan_compatibility_type);
    lua_setfield(L, -2, "type");
    lua_pushcfunction(L, titan_compatibility_next);
    lua_setfield(L, -2, "next");
    lua_pushcfunction(L, titan_compatibility_error);
    lua_setfield(L, -2, "error");
    if (lua_setupvalue(L, -2, 1) == NULL) lua_pop(L, 1);
}

static void titan_check_compatibility_entry(lua_State *L, void *raw,
    const char *sym, const char *file, const char *verifier,
    size_t verifier_size, const char *error) {
    typedef int (*titan_metadata_fn)(lua_State *);
    int top = lua_gettop(L);
    const char *source;
    size_t size;
    luaL_checkstack(L, 10, "loading Titan compatibility metadata");
    if (raw == NULL) {
        luaL_error(L, "Titan compiled module '%s' is missing compatibility "
            "symbol '%s': %s", file, sym, error ? error : "symbol not found");
    }
    titan_metadata_fn fn = titan_cast_func(titan_metadata_fn, raw);
    if (fn(L) != 1 || lua_gettop(L) != top + 1
        || lua_type(L, -1) != LUA_TSTRING) {
        lua_settop(L, top);
        luaL_error(L, "Titan compiled module '%s' has invalid compatibility "
            "metadata '%s'", file, sym);
    }
    source = lua_tolstring(L, -1, &size);
    titan_load_compatibility_chunk(L, source, size, sym);
    lua_call(L, 0, 1);
    lua_remove(L, top + 1); /* source remains rooted until evaluation finishes */
    titan_load_compatibility_chunk(L, verifier, verifier_size,
        "Titan dependency compatibility verifier");
    lua_call(L, 0, 1);
    lua_insert(L, -2); /* verifier function, provider metadata */
    lua_call(L, 1, 0);
    lua_settop(L, top);
}

/* Implementation notes: doc/implementation/binary-compatibility.md#generated-exports-and-runtime-verification */
void titan_check_module_compatibility(lua_State *L, TitanModuleProvider provider,
    const char *sym, const char *file, const char *verifier,
    size_t verifier_size) {
    const char *error;
    void *raw = titan_find_module_symbol(provider, sym, &error);
    titan_check_compatibility_entry(L, raw, sym, file, verifier,
        verifier_size, error);
}

/* Returns nonzero (and clears the pin) if the trace slot is pinned, i.e. a
** pending re-raise asked errorhandler to KEEP the existing TITAN_BACKTRACE_KEY
** slot rather than regenerate it. A fresh (unpinned) error regenerates. */
static int titan_trace_pinned(lua_State *L) {
  lua_pushliteral(L, TITAN_TRACE_PINNED);
  lua_rawget(L, LUA_REGISTRYINDEX);
  int pinned = lua_toboolean(L, -1);
  lua_pop(L, 1);
  if (pinned) {
    /* clear the pin: it is one-shot, consumed by this capture */
    lua_pushliteral(L, TITAN_TRACE_PINNED);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
  return pinned;
}

/* Implementation notes: doc/implementation/error-handling.md#runtime-trace-model */
int errorhandler(lua_State *L) {
  int top = lua_gettop(L);
  /* Pin discipline (A.5): a pinned slot belongs to a pending re-raise and must
  ** be preserved verbatim; only an unpinned (fresh) error regenerates it. This
  ** replaces the old always-overwrite (last-write-wins) behavior. */
  if (titan_trace_pinned(L)) {
    lua_settop(L, top);
    return 1;  /* keep existing TITAN_BACKTRACE_KEY slot; error obj stays on top */
  }

  /* Regenerate the raw traceback slot. luaL_Buffer lives on the stack from
  ** luaL_buffinit on and must stay at the top while in use, so push everything
  ** else first. */
#if defined(_WIN32) && !defined(TITAN_HAVE_LIBBACKTRACE)
  /* Root the Lua trace below the buffer: adding a long trace can grow its
  ** UBox, whose stack slot must remain the topmost value during appends. */
  luaL_traceback(L, L, NULL, 1);
  const char *lua_trace = lua_tostring(L, -1);
#endif
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  luaL_Buffer buf;
  luaL_buffinit(L, &buf);
#ifdef TITAN_HAVE_LIBBACKTRACE
  /* ONE intermingled, innermost->outer trace: the CallInfo chain
  ** supplies every Lua frame, libbacktrace supplies the Titan native frames
  ** spliced at the entry-wrapper boundaries. No separate "C traceback:" section,
  ** no collapsed [Lua] marker. */
  titan_push_unified_trace(L, &buf);
#else
  /* Fallback (no libbacktrace, e.g. musl/Alpine): store raw Lua traceback lines
  ** plus raw execinfo C frames. Without libbacktrace we cannot splice Titan
  ** frames into the Lua trace. */
  {
    int wrote_any = 0;
    void *nbuf[255];
    int calls;
#if !defined(_WIN32)
    char **bt;
#endif
#if defined(_WIN32)
    titan_add_raw_lua_trace(&buf, &wrote_any, lua_trace);
#else
    luaL_traceback(L, L, NULL, 1);
    titan_add_raw_lua_trace(&buf, &wrote_any, lua_tostring(L, -1));
    lua_pop(L, 1);
#endif
#if defined(_WIN32)
    /* Without libbacktrace, preserve Lua frames and report native addresses. */
    calls = CaptureStackBackTrace(0, sizeof(nbuf) / sizeof(void *), nbuf, NULL);
    for (int i = 0; i < calls; i++) {
      char frame[64];
      snprintf(frame, sizeof(frame), "[native address %p]", nbuf[i]);
      titan_bt_addframe(&buf, &wrote_any, frame);
    }
#else
    calls = backtrace(nbuf, sizeof(nbuf) / sizeof(void *));
    bt = backtrace_symbols(nbuf, calls);
    for (int i = 0; i < calls; i++) {
      titan_bt_addframe(&buf, &wrote_any, bt[i]);
    }
    free(bt);
#endif
  }
#endif
  luaL_pushresult(&buf);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_settop(L, top);
  return 1;
}

/*
** ===========================================================================
** Abandoned-coroutine unwinding
** ===========================================================================
*/

/* Implementation notes: doc/implementation/coroutines.md#unwinding-an-abandoned-coroutine */

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define TITAN_UNWIND_ASAN 1
#endif
#endif
#if defined(__SANITIZE_ADDRESS__) && !defined(TITAN_UNWIND_ASAN)
#define TITAN_UNWIND_ASAN 1
#endif
#if defined(TITAN_UNWIND_ASAN)
#include <sanitizer/asan_interface.h>
#endif

static void titan_unwind_abort(const char *why) {
  fprintf(stderr, "titan: abandoned coroutine unwind: %s\n", why);
  fflush(stderr);
  abort();
}

/* Integer key of an automatic object's real native-stack location. GCC's ASan
** may place frames that call setjmp (and their lua_longjmp) on the
** use-after-return fake stack; map such an address to the real-stack frame
** it stands for. The current fake stack is the running coroutine's, because
** minicoro saves and restores it per fiber. */
static uintptr_t titan_unwind_key(const void *address) {
#if defined(TITAN_UNWIND_ASAN)
  void *real = __asan_addr_is_in_fake_stack(__asan_get_current_fake_stack(),
                                            (void *)address, NULL, NULL);
  if (real != NULL) return (uintptr_t)real;
#endif
  return (uintptr_t)address;
}

static void titan_unwind_clear_registry_string(lua_State *L, const char *key) {
  TValue nil = {0};
  setnilvalue(&nil);
  /* Storing nil into an existing slot never allocates; an absent key has
  ** nothing to clear. */
  (void)luaH_psetstr(hvalue(&G(L)->l_registry), luaS_new(L, key), &nil);
}

static void titan_unwind_warn(lua_State *L, void *ud) {
  (void)ud;
  luaE_warnerror(L, "coroutine cleanup");
  /* A reported error is handled: keep a later titan.backtrace() from seeing
  ** its trace, as a catch recovery does. */
  titan_unwind_clear_registry_string(L, TITAN_BACKTRACE_KEY);
  titan_unwind_clear_registry_string(L, TITAN_TRACE_PINNED);
}

static void titan_unwind_clear_trace_aux(lua_State *L, void *ud) {
  (void)ud;
  titan_unwind_clear_registry_string(L, TITAN_BACKTRACE_KEY);
  titan_unwind_clear_registry_string(L, TITAN_TRACE_PINNED);
}

/* An unwind dropped an error whose trace the error handler had stored: clear
** the trace and its pin, as a catch recovery does. luaS_new can allocate on a
** string-cache miss, so the clears run protected; a failure leaves them. */
void titan_unwind_clear_trace(lua_State *L) {
  CallInfo *ci = L->ci;
  lu_byte allowhook = L->allowhook;
  ptrdiff_t errfunc = L->errfunc;
  ptrdiff_t top = savestack(L, L->top.p);
  (void)luaD_rawrunprotected(L, titan_unwind_clear_trace_aux, NULL);
  L->ci = ci;
  L->allowhook = allowhook;
  L->errfunc = errfunc;
  L->top.p = restorestack(L, top);
}

/* Report one cleanup error as a Lua warning and drop it. The error object is
** materialized above the current top; the reporting-time top is restored, so
** the open upvalues and pending to-be-closed slots of a failed __close stay
** below it. A failure while reporting is ignored; the reporter restores `ci`,
** `allowhook` and `errfunc` on every path. */
void titan_unwind_report(lua_State *L, TStatus status) {
  ptrdiff_t top = savestack(L, L->top.p);
  CallInfo *ci = L->ci;
  lu_byte allowhook = L->allowhook;
  ptrdiff_t errfunc = L->errfunc;
  luaD_seterrorobj(L, status, L->top.p);
  (void)luaD_rawrunprotected(L, titan_unwind_warn, NULL);
  L->ci = ci;
  L->allowhook = allowhook;
  L->errfunc = errfunc;
  L->top.p = restorestack(L, top);
}

static void titan_unwind_close_aux(lua_State *L, void *ud) {
  ptrdiff_t level = *(ptrdiff_t *)ud;
  luaF_close(L, restorestack(L, level), LUA_OK, 0);
}

/* luaD_closeprotected's loop with the unwind policy: every retry keeps
** LUA_OK, so each __close receives no error value, and each error is reported
** before the retry. luaF_close pops an entry before calling it, so the loop
** always progresses. `top` drops to `level` only once everything is closed.
** A failed __close may have jumped over a Titan Lua-entry wrapper that had
** installed its own message handler, so `errfunc` is restored after every
** failure, as luaD_pcall does, and holds its entry value on return. */
void titan_unwind_close(lua_State *L, ptrdiff_t level) {
  CallInfo *ci = L->ci;
  lu_byte allowhook = L->allowhook;
  ptrdiff_t errfunc = L->errfunc;
  for (;;) {
    TStatus status = luaD_rawrunprotected(L, titan_unwind_close_aux, &level);
    if (status == LUA_OK) break;
    L->errfunc = errfunc;
    titan_unwind_report(L, status);
    L->ci = ci;
    L->allowhook = allowhook;
  }
  L->errfunc = errfunc;
  L->top.p = restorestack(L, level);
}

l_noret titan_unwind_guard_failed(lua_State *L, lua_longjmp *guard,
                               l_uint32 oldnC, CallInfo *oldci, lu_byte oldah,
                               ptrdiff_t olderrfunc, ptrdiff_t level) {
  TStatus status = guard->status;
  L->errorJmp = guard->previous;
  L->nCcalls = oldnC;
  L->ci = oldci;
  L->allowhook = oldah;
  L->errfunc = olderrfunc;
  titan_unwind_report(L, status);
  titan_unwind_close(L, level);
  titan_unwind(L);
}

/* Close an exhausted Lua coroutine as dead, after all of its Titan cleanup and
** before any of its resumer's. Mirrors lstate.c resetCI (static there), then
** closes every remaining to-be-closed variable with the unwind policy. */
static void titan_unwind_close_thread(lua_State *L, lua_State *resumer) {
  CallInfo *ci;
  L->errorJmp = NULL;
  L->nCcalls = getCcalls(resumer);
  ci = L->ci = &L->base_ci;
  ci->func.p = L->stack.p;
  setnilvalue2s(ci->func.p);
  ci->top.p = ci->func.p + 1 + LUA_MINSTACK;
  ci->u.c.k = NULL;
  ci->callstatus = CIST_C;
  L->status = LUA_OK;
  L->errfunc = 0;
  titan_unwind_close(L, savestack(L, L->stack.p + 1));
  L->top.p = L->stack.p + 1;
  luaD_shrinkstack(L);
  L->nCcalls = 0;
}

/* The thread `L` holds no landing point: it is a Lua coroutine resumed on the
** coroutine stack being unwound. Find its resumer, close it, and return the
** resumer. Every compared address is an integer real-stack key. */
static lua_State *titan_unwind_cross(lua_State *L, lua_longjmp *outermost) {
  global_State *g = G(L);
  const titan_unwind_floor *floor = NULL;
  lua_State *resumer = NULL;
  uintptr_t position, best = 0;
  GCObject *o;
  if (outermost == NULL)
    titan_unwind_abort("an exhausted Lua thread has no protected boundary");
  position = titan_unwind_key(outermost);
  /* The armed floor whose recorded stack contains the position owns it. The
  ** main thread is linked into allgc, like every other thread. */
  for (o = g->allgc; o != NULL && floor == NULL; o = o->next) {
    lua_State *th;
    lua_longjmp *last;
    if (o->tt != LUA_VTHREAD) continue;
    th = gco2th(o);
    last = th->errorJmp;
    if (last == NULL) continue;
    while (last->previous != NULL) last = last->previous;
    if (last->status == TITAN_STATUS_FLOOR) {
      const titan_unwind_floor *candidate = (const titan_unwind_floor *)last;
      if (candidate->stack_low <= position && position < candidate->stack_high)
        floor = candidate;
    }
  }
  if (floor == NULL)
    titan_unwind_abort("no coroutine floor contains the exhausted Lua thread");
  /* The resumer is blocked in lua_resume(L): its innermost boundary is the
  ** nearest head above the exhausted thread's outermost boundary. */
  for (o = g->allgc; o != NULL; o = o->next) {
    lua_State *th;
    uintptr_t key;
    if (o->tt != LUA_VTHREAD) continue;
    th = gco2th(o);
    if (th == L || th->errorJmp == NULL) continue;
    key = titan_unwind_key(th->errorJmp);
    if (position < key && key < floor->stack_high &&
        (resumer == NULL || key < best)) {
      resumer = th;
      best = key;
    }
  }
  if (resumer == NULL)
    titan_unwind_abort("no resumer found for an exhausted Lua thread");
  titan_unwind_close_thread(L, resumer);
  return resumer;
}

/* Mark the floor at the bottom of the chain that holds `lj`, if that chain
** belongs to a Titan coroutine, as abandoned: a cleanup that then closes its
** own thread reaches the floor with LUA_OK and must still finish unwinding. */
static void titan_unwind_mark_floor(lua_longjmp *lj) {
  while (lj->previous != NULL) lj = lj->previous;
  if (lj->status == TITAN_STATUS_FLOOR)
    ((titan_unwind_floor *)lj)->unwinding = 1;
}

l_noret titan_unwind(lua_State *L) {
  for (;;) {
    lua_longjmp *outermost = NULL;
    lua_longjmp *lj;
    for (lj = L->errorJmp; lj != NULL; lj = lj->previous) {
      if (lj->status == TITAN_STATUS_FINALLY ||
          lj->status == TITAN_STATUS_FLOOR) {
        titan_unwind_mark_floor(lj);
        lj->status = TITAN_STATUS_UNWIND;
        TITAN_LONGJMP(lj->b);
      }
      outermost = lj;
    }
    L = titan_unwind_cross(L, outermost);
  }
}
