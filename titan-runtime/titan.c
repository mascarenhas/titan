#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
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

const void *titan_publish_function_type_tag(lua_State *L,
                                            const char *registry_key,
                                            const void *candidate) {
    int base;
    const void *canonical;

    if (registry_key == NULL || registry_key[0] == '\0')
        luaL_error(L, "invalid Titan function-type registry key");
    if (candidate == NULL)
        luaL_error(L, "invalid Titan function-type tag candidate");
    if (!lua_checkstack(L, 1))
        luaL_error(L, "stack overflow publishing Titan function-type tag");
    base = lua_gettop(L);

    /*
    ** The type-specific string slot elects one canonical tag independently of
    ** module/provider load order. A later publisher recovers that pointer
    ** rather than publishing its own translation-unit-local candidate.
    */
    lua_getfield(L, LUA_REGISTRYINDEX, registry_key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        canonical = candidate;
        lua_pushlightuserdata(L, (void *)canonical);
        lua_setfield(L, LUA_REGISTRYINDEX, registry_key);
    }
    else {
        if (!lua_islightuserdata(L, -1))
            luaL_error(L, "invalid Titan function-type tag registry entry");
        canonical = lua_touserdata(L, -1);
        lua_pop(L, 1);
    }

    lua_settop(L, base);
    return canonical;
}

static Table *titan_array_callback_metatable(lua_State *L) {
    TValue value = lua_totvalue(L, lua_upvalueindex(1));
    if (!ttistable(&value))
        luaL_error(L, "invalid Titan array metatable");
    return hvalue(&value);
}

lua_Unsigned titan_array_length(const Table *backing) {
    if (backing->asize == 0)
        return 0;
    lua_assert(*lenhint(backing) <= backing->asize);
    return *lenhint(backing);
}

void titan_array_set_length(Table *backing, lua_Unsigned length) {
    if (backing->asize == 0) {
        lua_assert(length == 0);
        return;
    }
    lua_assert(length <= backing->asize);
    *lenhint(backing) = cast_uint(length);
}

static int titan_array_valid_length(const Table *backing) {
    return backing->asize == 0 || *lenhint(backing) <= backing->asize;
}

Udata *titan_array_try_proxy(Table *backing, Table *metatable) {
    TValue value;
    Udata *proxy;

    if (backing == NULL || metatable == NULL ||
        backing->metatable != NULL || !titan_array_valid_length(backing))
        return NULL;
    if (tagisempty(luaH_getint(backing, 0, &value)) ||
        !ttisfulluserdata(&value))
        return NULL;
    proxy = uvalue(&value);
    if (proxy->len != 0 || proxy->nuvalue != 2 ||
        proxy->metatable != metatable ||
        !ttistable(&proxy->uv[0].uv) ||
        hvalue(&proxy->uv[0].uv) != backing)
        return NULL;
    return proxy;
}

Udata *titan_array_require_proxy(lua_State *L, Table *backing,
                                 Table *metatable) {
    Udata *proxy = titan_array_try_proxy(backing, metatable);
    if (proxy == NULL)
        luaL_error(L, "invalid Titan array backing");
    return proxy;
}

Table *titan_array_try_backing(const TValue *value, Table *metatable) {
    Udata *proxy;
    Table *backing;
    TValue cycle;

    if (metatable == NULL || !ttisfulluserdata(value))
        return NULL;
    proxy = uvalue(value);
    if (proxy->len != 0 || proxy->nuvalue != 2 ||
        proxy->metatable != metatable ||
        !ttistable(&proxy->uv[0].uv))
        return NULL;
    backing = hvalue(&proxy->uv[0].uv);
    if (backing->metatable != NULL || !titan_array_valid_length(backing))
        return NULL;
    if (tagisempty(luaH_getint(backing, 0, &cycle)) ||
        !ttisfulluserdata(&cycle) || uvalue(&cycle) != proxy)
        return NULL;
    return backing;
}

Table *titan_array_require_backing(lua_State *L, const TValue *value,
                                   Table *metatable) {
    Table *backing = titan_array_try_backing(value, metatable);
    if (backing == NULL)
        luaL_error(L, "expected Titan array");
    return backing;
}

unsigned titan_array_growth(lua_State *L, lua_Unsigned index) {
    unsigned capacity = 2;

    if (index < 1)
        luaL_error(L, "Titan array index must be positive");
    while ((lua_Unsigned)capacity <= index) {
        if (capacity > TITAN_ARRAY_MAX_CAPACITY / 2u)
            luaL_error(L, "array index too large");
        capacity *= 2u;
    }
    if (capacity > TITAN_ARRAY_MAX_CAPACITY)
        luaL_error(L, "array index too large");
    return capacity;
}

void titan_array_resize(lua_State *L, Table *backing,
                        lua_Unsigned capacity) {
    lua_Unsigned length;

    if (capacity > TITAN_ARRAY_MAX_CAPACITY)
        luaL_error(L, "array index too large");
    if (capacity < backing->asize)
        luaL_error(L, "cannot shrink Titan array backing");
    if (capacity == backing->asize)
        return;
    length = titan_array_length(backing);
    lua_assert(length <= capacity);
    luaH_resizearray(L, backing, cast_uint(capacity));
    titan_array_set_length(backing, length);
}

lu_byte titan_array_get(Table *backing, lua_Integer index, TValue *result) {
    lua_Unsigned offset;
    lu_byte tag;

    if (index < 1) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    offset = l_castS2U(index) - 1u;
    if (offset >= backing->asize) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    tag = *getArrTag(backing, cast_uint(offset));
    if (tagisempty(tag)) {
        setnilvalue(result);
        return LUA_VNIL;
    }
    farr2val(backing, cast_uint(offset), tag, result);
    return tag;
}

void titan_array_set_stack(lua_State *L, Table *backing, lua_Integer index,
                           int value_index) {
    TValue value;
    lua_Unsigned logical_index;
    lua_Unsigned length;
    unsigned offset;

    if (index < 1)
        luaL_error(L, "Titan array index must be positive");
    logical_index = l_castS2U(index);
    value = lua_totvalue(L, value_index);
    length = titan_array_length(backing);

    if (logical_index > backing->asize) {
        if (ttisnil(&value))
            return;
        titan_array_resize(L, backing, titan_array_growth(L, logical_index));
        /*
        ** The value remains rooted at value_index while resize can allocate
        ** and move the Lua stack. Refresh the copy after that allocation.
        */
        value = lua_totvalue(L, value_index);
    }

    offset = cast_uint(logical_index - 1u);
    obj2arr(backing, offset, &value);
    luaC_barrierback(L, obj2gco(backing), &value);

    if (ttisnil(&value)) {
        if (logical_index == length) {
            do {
                length--;
            } while (length > 0 &&
                     tagisempty(*getArrTag(backing, cast_uint(length - 1u))));
            titan_array_set_length(backing, length);
        }
    }
    else if (logical_index > length) {
        titan_array_set_length(backing, logical_index);
    }
}

static int titan_array_lua_index(lua_State *L) {
    Table *metatable = titan_array_callback_metatable(L);
    TValue receiver = lua_totvalue(L, 1);
    Table *backing =
        titan_array_require_backing(L, &receiver, metatable);
    lua_Integer index;
    TValue result;

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
        Udata *proxy =
            titan_array_try_proxy(hvalue(&result), metatable);
        if (proxy != NULL)
            setuvalue(L, &result, proxy);
    }
    lua_pushtvalue(L, result);
    return 1;
}

static int titan_array_lua_newindex(lua_State *L) {
    Table *metatable = titan_array_callback_metatable(L);
    TValue receiver = lua_totvalue(L, 1);
    Table *backing =
        titan_array_require_backing(L, &receiver, metatable);
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

    /*
    ** Nil is the representation-independent deletion operation. In
    ** particular, deleting beyond the current capacity remains an
    ** allocation-free no-op and never invokes the type-directed writer.
    */
    if (lua_isnil(L, 3)) {
        titan_array_set_stack(L, backing, index, 3);
        return 0;
    }

    /*
    ** Classify an oversized positive write before running user-visible
    ** conversion code. titan_array_growth is a pure preflight here; the
    ** actual resize happens only after the writer succeeds.
    */
    logical_index = l_castS2U(index);
    if (logical_index > backing->asize)
        cast_void(titan_array_growth(L, logical_index));

    /*
    ** Construction installed a generated CClosure in uv[1]. Ordinary Array
    ** validation deliberately never reads that slot: the shared metatable and
    ** uv[0]/key-0 cycle remain the hot Array identity check. The debug library
    ** can violate this private invariant, as it can other Titan invariants.
    */
    if (!lua_checkstack(L, 2))
        return luaL_error(L, "stack overflow writing Titan array");
    lua_pushtvalue(L, proxy->uv[1].uv);
    lua_pushvalue(L, 3);
    lua_call(L, 1, 1);

    /*
    ** The converted result is stack-rooted across any resize. No backing
    ** mutation, capacity change, length change, or barrier occurs until this
    ** point, so a writer error leaves the Array untouched.
    */
    titan_array_set_stack(L, backing, index, -1);
    lua_pop(L, 1);
    return 0;
}

static int titan_array_lua_len(lua_State *L) {
    Table *metatable = titan_array_callback_metatable(L);
    TValue receiver = lua_totvalue(L, 1);
    Table *backing =
        titan_array_require_backing(L, &receiver, metatable);
    lua_pushinteger(L, cast_Integer(titan_array_length(backing)));
    return 1;
}

Table *titan_array_metatable(lua_State *L) {
    static const luaL_Reg callbacks[] = {
        {"__index", titan_array_lua_index},
        {"__newindex", titan_array_lua_newindex},
        {"__len", titan_array_lua_len},
        {NULL, NULL}
    };
    Table *metatable;

    luaL_getmetatable(L, TITAN_ARRAY_METATABLE);
    if (lua_isnil(L, -1)) {
        TValue value;

        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushliteral(L, TITAN_ARRAY_METATABLE);
        lua_setfield(L, -2, "__name");
        lua_pushliteral(L, TITAN_ARRAY_METATABLE);
        lua_setfield(L, -2, "__metatable");

        lua_pushvalue(L, -1);
        luaL_setfuncs(L, callbacks, 1);
        value = lua_totvalue(L, -1);
        lua_assert(ttistable(&value));
        metatable = hvalue(&value);

        /* Publish only after all allocating initialization has succeeded. */
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
    }
    else {
        TValue value = lua_totvalue(L, -1);
        if (!ttistable(&value))
            luaL_error(L, "invalid Titan array metatable registry entry");
        metatable = hvalue(&value);
    }
    lua_pop(L, 1);
    return metatable;
}

Table *titan_array_new(lua_State *L, Table *metatable,
                       lua_Unsigned capacity, const TValue *writer) {
    int base;
    int writer_index;
    int backing_index;
    int proxy_index;
    Table *backing;
    Udata *proxy;
    TValue value;
    TValue writer_value;

    if (metatable == NULL)
        luaL_error(L, "invalid Titan array metatable");
    if (writer == NULL)
        luaL_error(L, "invalid Titan array writer");
    writer_value = *writer;
    if (!ttisCclosure(&writer_value))
        luaL_error(L, "invalid Titan array writer");
    if (capacity > TITAN_ARRAY_MAX_CAPACITY)
        luaL_error(L, "array index too large");
    if (!lua_checkstack(L, 4))
        luaL_error(L, "stack overflow creating Titan array");

    base = lua_gettop(L);
    /*
    ** Root the writer before either construction object is allocated. The
    ** caller also owns a root (normally the module's cached private slot), but
    ** this local stack root makes all later allocation/barrier ordering
    ** self-contained.
    */
    lua_pushtvalue(L, writer_value);
    writer_index = base + 1;

    backing = luaH_new(L);
    sethvalue(L, &value, backing);
    lua_pushtvalue(L, value);
    backing_index = base + 2;

    lua_newuserdatauv(L, 0, 2);
    proxy_index = base + 3;
    value = lua_totvalue(L, proxy_index);
    proxy = uvalue(&value);

    sethvalue(L, &value, metatable);
    lua_pushtvalue(L, value);
    lua_setmetatable(L, proxy_index);

    luaH_resize(L, backing, cast_uint(capacity), 1);
    titan_array_set_length(backing, 0);

    {
        int set;
        lua_pushvalue(L, backing_index);
        set = lua_setiuservalue(L, proxy_index, 1);
        lua_assert(set);
        cast_void(set);
    }

    {
        int set;
        lua_pushvalue(L, writer_index);
        set = lua_setiuservalue(L, proxy_index, 2);
        lua_assert(set);
        cast_void(set);
    }

    value = lua_totvalue(L, proxy_index);
    luaH_setint(L, backing, 0, &value);
    /*
    ** luaH_setint can force a full collection under HARDMEMTESTS. Both
    ** objects stay independently stack-rooted throughout; refresh the proxy
    ** TValue before installing the ordinary backward barrier.
    */
    value = lua_totvalue(L, proxy_index);
    luaC_barrierback(L, obj2gco(backing), &value);

    lua_assert(titan_array_try_proxy(backing, metatable) == proxy);
    cast_void(proxy);
    lua_settop(L, base);
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
** dlopened .so to a #line-attributed .titan file/line (and recovers inlined
** frames); the old execinfo path is kept as a no-DWARF fallback for platforms
** without libbacktrace (e.g. musl/Alpine). Define TITAN_NO_LIBBACKTRACE to
** force the fallback. */
#ifndef TITAN_NO_LIBBACKTRACE
#include "backtrace.h"
#define TITAN_HAVE_LIBBACKTRACE 1
#else
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
** symbolization, and never re-scans (it caches the dl_iterate_phdr result). A
** module dlopened after that snapshot would have no symbols, so loadlib() and
** generated luaopen_* functions invalidate this cached state after successful
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

/* Reset after a slow-path dlopen or a Lua require that mapped a Titan .so.
** Every titan.o copy clears the same per-state registry slot. The next capture
** recreates it with the now-complete process image snapshot. */
void titan_invalidate_backtrace_state(lua_State *L) {
    int top = lua_gettop(L);
    lua_pushliteral(L, TITAN_BT_STATE_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_settop(L, top);
}

static const char *titan_basename(const char *path) {
    const char *slash = path ? strrchr(path, '/') : NULL;
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

static int titan_bt_collect_cb(void *data, uintptr_t pc, const char *filename,
                               int lineno, const char *function) {
    titan_native_stack *st = (titan_native_stack *)data;
    const char *base;
    int is_titan, is_entry;
    (void)pc;
    if (st->n >= st->cap) return 0;             /* full: stop collecting */
    if (filename == NULL) return 0;             /* unsymbolized: drop */
    base = titan_basename(filename);
    if (strstr(filename, "titan-runtime/")) return 0;  /* runtime: drop */
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

static int push_package_cpath_root(lua_State *L) {
    int top = lua_gettop(L);
    lua_getglobal(L, "package");
    if(lua_istable(L, -1) && lua_getfield(L, -1, "cpath") == LUA_TSTRING) {
        size_t path_len;
        const size_t suffix_len = sizeof(TITAN_LUA_CPATH_SUFFIX) - 1;
        const char *path = lua_tolstring(L, -1, &path_len);
        const char *entry = path;
        const char *limit = path + path_len;
        while(entry <= limit) {
            const char *end = memchr(entry, ';', (size_t)(limit - entry));
            size_t entry_len;
            size_t root_len;
            if(end == NULL) end = limit;
            entry_len = (size_t)(end - entry);
            if(entry_len >= suffix_len &&
               memcmp(entry + entry_len - suffix_len,
                      TITAN_LUA_CPATH_SUFFIX, suffix_len) == 0) {
                root_len = entry_len - suffix_len;
                while(root_len > 1 && entry[root_len - 1] == '/') root_len--;
                if(root_len == 0) {
                    lua_pushliteral(L, "/");
                } else {
                    lua_pushlstring(L, entry, root_len);
                }
                lua_replace(L, top + 1);
                lua_settop(L, top + 1);
                return 1;
            }
            if(end == limit) break;
            entry = end + 1;
        }
    }
    lua_settop(L, top);
    return 0;
}

static void pushroot(lua_State *L) {
    lua_pushliteral(L, TITAN_ROOT_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if(lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);
        if(!push_package_cpath_root(L)) {
            lua_pushliteral(L, TITAN_ROOT_DEFAULT);
        }
        lua_pushliteral(L, TITAN_ROOT_KEY);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}

static void push_root_path(lua_State *L, const char *suffix) {
    size_t root_len;
    const char *root;
    pushroot(L);
    root = lua_tolstring(L, -1, &root_len);
    if(root_len == 1 && root[0] == '/') {
        lua_pushstring(L, suffix);
    } else {
        lua_pushfstring(L, "%s%s", root, suffix);
    }
    lua_remove(L, -2);
}

static void push_default_titan_path(lua_State *L) {
    const char *installed;
    push_root_path(L, "/lib/titan/" TITAN_VER);
    installed = lua_tostring(L, -1);
    lua_pushfstring(L, ".;%s", installed);
    lua_remove(L, -2);
}

static void pushpath (lua_State *L) {
    lua_pushliteral(L, TITAN_PATH_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);

        /* Try the versioned name for the Titan Path variable */
        const char *path = getenv(TITAN_PATH_VAR TITAN_VER_SUFFIX);
        if (path == NULL) {
            /* Try the unversioned name for the Titan Path variable */
            path = getenv(TITAN_PATH_VAR);
        }
        if (path == NULL) {
            /* No Titan Path environment variable */
            push_default_titan_path(L);
        } else {
            const char *default_path;
            push_default_titan_path(L);
            default_path = lua_tostring(L, -1);
            path = luaL_gsub(L, path, ";;", ";\1;");
            path = luaL_gsub(L, path, "\1", default_path);
            lua_remove(L, -2); /* remove result from 1st 'gsub' */
            lua_remove(L, -2); /* remove default Titan path */
        }
        lua_pushliteral(L, TITAN_PATH_KEY);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}

static int path_has_template(const char *path, size_t path_len,
                             const char *target, size_t target_len) {
    const char *entry = path;
    const char *limit = path + path_len;
    while(entry <= limit) {
        const char *end = memchr(entry, ';', (size_t)(limit - entry));
        size_t entry_len;
        if(end == NULL) end = limit;
        entry_len = (size_t)(end - entry);
        if(entry_len == target_len && memcmp(entry, target, target_len) == 0) {
            return 1;
        }
        if(end == limit) break;
        entry = end + 1;
    }
    return 0;
}

static void add_titan_package_cpath(lua_State *L) {
    int top = lua_gettop(L);
    lua_getglobal(L, "package");
    if(lua_istable(L, -1) && lua_getfield(L, -1, "cpath") == LUA_TSTRING) {
        size_t path_len;
        size_t template_len;
        const char *path = lua_tolstring(L, -1, &path_len);
        const char *template;
        push_root_path(L, "/lib/titan/" TITAN_VER "/?.so");
        template = lua_tolstring(L, -1, &template_len);
        if(!path_has_template(path, path_len, template, template_len)) {
            if(path_len == 0) {
                lua_pushvalue(L, -1);
            } else {
                lua_pushfstring(L, "%s;%s", template, path);
            }
            lua_setfield(L, top + 1, "cpath");
        }
    }
    lua_settop(L, top);
}

void titan_init_paths(lua_State *L) {
    int top = lua_gettop(L);
    pushroot(L);
    lua_pop(L, 1);
    add_titan_package_cpath(L);
    pushpath(L);
    lua_pop(L, 1);
    lua_settop(L, top);
}

static const char *pushnextdir (lua_State *L, const char *path) {
    const char *l;
    while (*path == ';') path++;  /* skip separators */
    if (*path == '\0') return NULL;  /* no more templates */
    l = strchr(path, ';');  /* find next separator */
    if (l == NULL) l = path + strlen(path);
    lua_pushlstring(L, path, l - path);  /* template */
    return l;
}

static void createlibstable (lua_State *L) {
    lua_newtable(L);
    /* Keep Titan DSOs mapped for the process lifetime.  A flat load-order
    ** finalizer cannot safely unload a manually wired dependency graph: the
    ** required order depends on which module was initialized first, and Lua
    ** finalizers can still hold native entry pointers.  The old string-only
    ** table's luaL_len was zero, so it also never actually called dlclose. */
    lua_pushliteral(L, TITAN_LIBS_KEY);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static void pushlibs(lua_State *L) {
    lua_pushliteral(L, TITAN_LIBS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);
        createlibstable(L);
    }
}

static void *loadlibfrompath(lua_State *L, const char *file) {
    pushlibs(L);
    lua_pushstring(L, file);
    lua_rawget(L, -2); // try to get lib
    if(!lua_isnil(L, -1)) {
        void *lib = lua_touserdata(L, -1);
        lua_pop(L, 2); // pop lib and libs table
        return lib;
    } else {
        lua_pop(L, 1); // pop nil
        pushpath(L);
        const char *path = lua_tostring(L, -1);
        while((path = pushnextdir(L, path)) != NULL) {
            const char *dir = lua_tostring(L, -1);
            lua_pushfstring(L, "%s" TITAN_PATH_SEP "%s", dir, file);
            const char *filename = lua_tostring(L, -1);
            /* A module's initializer loads its dynamic imports only after this
            ** dlopen returns, so ordinary unresolved calls must bind lazily.
            ** Titan's generated names share one process namespace; publishing
            ** every imported image lets those later imports satisfy the calls
            ** without module-specific loader rules. */
            void *lib = dlopen(filename, RTLD_LAZY | RTLD_GLOBAL);
            if(lib != NULL) {
                /* A new .so is now mapped: invalidate libbacktrace's one-time
                ** object snapshot so the next capture re-scans and can
                ** symbolize frames inside this module (the cached-handle fast
                ** path above loads nothing, so it must NOT invalidate). */
                titan_invalidate_backtrace_state(L);
                lua_pop(L, 3); // pop path, filename, and dir
                lua_pushstring(L, file);
                lua_pushlightuserdata(L, lib);
                lua_rawset(L, -3); // add to libs table
                lua_pop(L, 1); // pop libs table
                return lib;
            }
            lua_pop(L, 2); // pop filename and dir
        }
        lua_pop(L, 2); // pop path and libs table
        const char *err = dlerror();
        luaL_error(L, "cannot load module '%s': %s", file,
            err != NULL ? err : "search path is empty");
        return NULL;
    }
}

void *loadlib (lua_State *L, const char *file) {
    return loadlibfrompath(L, file);
}

void *loadsym (lua_State *L, void *lib, const char *sym) {
    void *f = dlsym(lib, sym);
    if(f == NULL) luaL_error(L, dlerror());
    return f;
}

void *loadglobalsym (lua_State *L, const char *sym) {
    void *f;
    const char *err;
    dlerror();  /* clear stale error; a NULL symbol value can be valid */
    f = dlsym(RTLD_DEFAULT, sym);
    err = dlerror();
    if(err != NULL) luaL_error(L, "%s", err);
    return f;
}

void titan_check_abi(lua_State *L, void *lib, const char *sym,
                     const char *file) {
    typedef int (*titan_abi_fn)(lua_State *);
    void *raw;
    titan_abi_fn fn;
    int top = lua_gettop(L);
    int nresults;
    const char *actual;
    dlerror();  /* clear stale error */
    raw = dlsym(lib, sym);
    if (raw == NULL) {
        const char *err = dlerror();
        luaL_error(L,
            "Titan compiled module '%s' is missing ABI symbol '%s' "
            "(expected ABI " TITAN_VER "): %s",
            file, sym, err ? err : "symbol not found");
    }
    fn = titan_cast_func(titan_abi_fn, raw);
    nresults = fn(L);
    if (nresults != 1 || !lua_isstring(L, -1)) {
        lua_settop(L, top);
        luaL_error(L,
            "Titan compiled module '%s' has an invalid ABI marker '%s' "
            "(expected ABI " TITAN_VER ")",
            file, sym);
    }
    actual = lua_tostring(L, -1);
    if (strcmp(actual, TITAN_VER) != 0) {
        luaL_error(L,
            "Titan compiled module '%s' ABI mismatch: expected " TITAN_VER
            " but found %s",
            file, actual);
    }
    lua_settop(L, top);
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
    char **bt;
    luaL_traceback(L, L, NULL, 1);
    titan_add_raw_lua_trace(&buf, &wrote_any, lua_tostring(L, -1));
    lua_pop(L, 1);
    calls = backtrace(nbuf, sizeof(nbuf) / sizeof(void *));
    bt = backtrace_symbols(nbuf, calls);
    for (int i = 0; i < calls; i++) {
      titan_bt_addframe(&buf, &wrote_any, bt[i]);
    }
    free(bt);
  }
#endif
  luaL_pushresult(&buf);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_settop(L, top);
  return 1;
}
