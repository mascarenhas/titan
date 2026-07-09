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
#include "lobject.h"
#include "llimits.h"
#include "titan.h"

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
** never freed (a small, bounded leak), never recreated per-error. */
static struct backtrace_state *titan_bt_state = NULL;
static lua_Integer titan_bt_generation_seen = -1;

static void titan_bt_error(void *data, const char *msg, int errnum) {
    (void)data; (void)msg; (void)errnum;  /* swallow: a missing frame is fine */
}

/* Reset after a slow-path dlopen or a Lua require that mapped a Titan .so. Each
** Titan .so links its own titan.o, so also bump a per-state registry generation:
** every module's errorhandler checks it before reusing its local C static state. */
void titan_invalidate_backtrace_state(lua_State *L) {
    lua_Integer gen = 0;
    titan_bt_state = NULL;
    lua_pushliteral(L, TITAN_BT_GENERATION_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_isinteger(L, -1)) {
        gen = lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
    lua_pushliteral(L, TITAN_BT_GENERATION_KEY);
    lua_pushinteger(L, gen + 1);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static void titan_sync_backtrace_generation(lua_State *L) {
    lua_Integer gen = 0;
    lua_pushliteral(L, TITAN_BT_GENERATION_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_isinteger(L, -1)) {
        gen = lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
    if (titan_bt_generation_seen != gen) {
        titan_bt_state = NULL;
        titan_bt_generation_seen = gen;
    }
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
    (void)L;
    if (titan_bt_state == NULL) {
        titan_bt_state = backtrace_create_state(NULL, 1, titan_bt_error, NULL);
    }
    if (titan_bt_state == NULL) return 0;
    /* skip=1: drop errorhandler's own frame. */
    backtrace_full(titan_bt_state, 1, titan_bt_collect_cb, titan_bt_error, st);
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
    titan_entry_probe probe;
    probe.is_entry = 0;
    (void)L;
    if (titan_bt_state == NULL) {
        titan_bt_state = backtrace_create_state(NULL, 1, titan_bt_error, NULL);
    }
    if (titan_bt_state == NULL) return 0;
    backtrace_syminfo(titan_bt_state,
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

static void add_package_cpath_dirs(lua_State *L, luaL_Buffer *buf) {
    int top = lua_gettop(L);
    lua_getglobal(L, "package");
    if(lua_istable(L, -1) && lua_getfield(L, -1, "cpath") == LUA_TSTRING) {
        const char *path = lua_tostring(L, -1);
        while(path && *path != '\0') {
            const char *end = strchr(path, ';');
            const char *q;
            if(end == NULL) end = path + strlen(path);
            q = memchr(path, '?', end - path);
            if(q != NULL) {
                const char *dir_end = q;
                while(dir_end > path && (dir_end[-1] == '/' || dir_end[-1] == '\\')) {
                    dir_end--;
                }
                if(dir_end > path) {
                    luaL_addchar(buf, ';');
                    luaL_addlstring(buf, path, dir_end - path);
                }
            }
            path = end;
            if(*path == ';') path++;
        }
    }
    lua_settop(L, top);
}

static void push_default_titan_path(lua_State *L) {
    luaL_Buffer buf;
    luaL_buffinit(L, &buf);
    luaL_addstring(&buf, TITAN_PATH_DEFAULT);
    add_package_cpath_dirs(L, &buf);
    luaL_pushresult(&buf);
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

static const char *pushnextdir (lua_State *L, const char *path) {
    const char *l;
    while (*path == ';') path++;  /* skip separators */
    if (*path == '\0') return NULL;  /* no more templates */
    l = strchr(path, ';');  /* find next separator */
    if (l == NULL) l = path + strlen(path);
    lua_pushlstring(L, path, l - path);  /* template */
    return l;
}

static int gctm (lua_State *L) {
    lua_Integer n = luaL_len(L, 1);
    /* for each handle, in reverse order */
    for (; n >= 1; n--) {
        lua_rawgeti(L, 1, n);  /* get handle LIBS[n] */
        dlclose(lua_touserdata(L, -1));
        lua_pop(L, 1);  /* pop handle */
    }
    return 0;
}

static void createlibstable (lua_State *L) {
    lua_newtable(L);
    lua_createtable(L, 0, 1);  /* create metatable */
    lua_pushcfunction(L, gctm);
    lua_setfield(L, -2, "__gc");  /* set finalizer */
    lua_setmetatable(L, -2);
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

void *loadlib (lua_State *L, const char *file) {
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
            void *lib = dlopen(filename, RTLD_NOW | RTLD_LOCAL);
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
        luaL_error(L, dlerror());
        return NULL;
    }
}

void *loadsym (lua_State *L, void *lib, const char *sym) {
    void *f = dlsym(lib, sym);
    if(f == NULL) luaL_error(L, dlerror());
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

static int titan_errfunc_is_errorhandler(lua_State *L) {
  if (L->errfunc == 0) return 0;
  StkId errfunc = restorestack(L, L->errfunc);
  TValue *v = s2v(errfunc);
  return ttislcf(v) && fvalue(v) == errorhandler;
}

static void titan_install_errorhandler(lua_State *L) {
  if (!titan_errfunc_is_errorhandler(L)) {
    lua_pushcfunction(L, errorhandler);
    L->errfunc = savestack(L, L->top.p - 1);
  }
}

lua_State *titan_newthread(lua_State *L) {
  lua_State *T = lua_newthread(L);
  titan_install_errorhandler(T);
  return T;
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
#ifdef TITAN_HAVE_LIBBACKTRACE
  titan_sync_backtrace_generation(L);
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

/*
 * Adapted from lapi.c.
*/
#define titan_ispseudo(i) ((i) <= LUA_REGISTRYINDEX)

static TValue *index2value (lua_State *L, int idx) {
  CallInfo *ci = L->ci;
  if (idx > 0) {
    StkId o = ci->func.p + idx;
    api_check(L, idx <= ci->top.p - (ci->func.p + 1), "unacceptable index");
    if (o >= L->top.p) return &G(L)->nilvalue;
    else return s2v(o);
  }
  else if (!titan_ispseudo(idx)) {  /* negative index */
    api_check(L, idx != 0 && -idx <= L->top.p - (ci->func.p + 1),
                 "invalid index");
    return s2v(L->top.p + idx);
  }
  else if (idx == LUA_REGISTRYINDEX)
    return &G(L)->l_registry;
  else {  /* upvalues */
    idx = LUA_REGISTRYINDEX - idx;
    api_check(L, idx <= MAXUPVAL + 1, "upvalue index too large");
    if (ttisCclosure(s2v(ci->func.p))) {  /* C closure? */
      CClosure *func = clCvalue(s2v(ci->func.p));
      return (idx <= func->nupvalues) ? &func->upvalue[idx-1]
                                      : &G(L)->nilvalue;
    }
    else {  /* light C function or Lua function (through a hook)?) */
      api_check(L, ttislcf(s2v(ci->func.p)), "caller not a C function");
      return &G(L)->nilvalue;  /* no upvalues */
    }
  }
}

TValue lua_totvalue(lua_State *L, int idx) {
  return *index2value(L, idx);
}

void lua_pushtvalue(lua_State *L, TValue v) {
  setobj2s(L, L->top.p, &v);
  L->top.p++;
}

void *lua_togco(lua_State *L, int idx) {
  TValue *o = index2value(L, idx);
  return gcvalue(o);
}
