#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"
#include "llimits.h"
#include "titan.h"

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

#ifdef TITAN_HAVE_LIBBACKTRACE
/* libbacktrace snapshots the set of loaded objects ONCE, on the first
** symbolization, and never re-scans (it caches the dl_iterate_phdr result). A
** module dlopened after that snapshot would have no symbols, so loadlib()
** invalidates this cached state (sets it NULL) after every successful dlopen on
** the slow path; the next capture lazily re-creates it and re-snapshots. The
** state is never freed (a small, bounded leak), never recreated per-error. */
static struct backtrace_state *titan_bt_state = NULL;

static void titan_bt_error(void *data, const char *msg, int errnum) {
    (void)data; (void)msg; (void)errnum;  /* swallow: a missing frame is fine */
}

/* Reset after a slow-path dlopen so the next capture sees the new .so. */
void titan_invalidate_backtrace_state(void) {
    titan_bt_state = NULL;
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
** dropped at capture time and never reach this array. */
typedef struct {
    char text[512];   /* preformatted "\t<file>:<line>: in <fn>" for a function */
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
        snprintf(f->text, sizeof(f->text), "\t%s:%d: in %s",
                 base ? base : "?", lineno, function ? function : "?");
    }
    return 0;
}

/* Capture the filtered native stack (Titan frames + entry-wrapper boundaries
** only) into `st`, innermost->outer. Returns 0 if libbacktrace is unavailable. */
static int titan_capture_native(titan_native_stack *st) {
    if (titan_bt_state == NULL) {
        titan_bt_state = backtrace_create_state(NULL, 1, titan_bt_error, NULL);
    }
    if (titan_bt_state == NULL) return 0;
    /* skip=1: drop errorhandler's own frame. */
    backtrace_full(titan_bt_state, 1, titan_bt_collect_cb, titan_bt_error, st);
    return 1;
}

static void titan_bt_addframe(luaL_Buffer *buf, int *wrote_any,
                              const char *text) {
    if (*wrote_any) luaL_addchar(buf, '\n');
    luaL_addstring(buf, text);
    *wrote_any = 1;
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

/* Build ONE intermingled, innermost->outer trace mixing pure-Lua and Titan
** frames in call order (plan A.2). The CallInfo chain is the backbone: it
** enumerates every Lua activation (so a single native luaV_execute correctly
** expands into the multiple Lua frames it ran). The native libbacktrace stack
** supplies only the Titan native frames, spliced in at the entry-wrapper
** boundaries.
**
** Alignment: walk both stacks innermost->outer in lockstep. At every C-level
** CallInfo (a Titan entry wrapper appears here as a C function, as do genuine
** Lua C-functions) we drain the next run of native Titan frames up to and
** including the next entry-wrapper sentinel and emit them; that sentinel-
** terminated run is the Titan native subtree that this Lua->Titan call ran.
** Pure-Lua CallInfo frames are emitted directly with src:line:in name; genuine
** Lua C-functions as [C]:in name. The deepest (innermost) Titan native run is
** drained before the first CallInfo so the error site leads the trace.
**
** Caveat (documented for review): a Titan entry wrapper and a genuine Lua
** C-function are indistinguishable at a C-level CallInfo, so the native Titan
** run is drained greedily at the first C-level CallInfo at or after its place.
** In the strictly-alternating Lua<->Titan case (the common one, and the tested
** one) this is exact. In the rarer Titan -> LuaC(e.g. pcall) -> Titan case the
** inner Titan native run may splice one C-frame too early; no frame is ever
** dropped (every Lua frame and every Titan frame appears) and the trace stays a
** single innermost->outer section. */
static void titan_push_unified_trace(lua_State *L, luaL_Buffer *buf,
                                     const char *msg) {
    titan_native_frame frames[TITAN_MAX_NATIVE];
    titan_native_stack st;
    int ni = 0;          /* next un-emitted native frame index */
    int wrote_any = 0;
    int level = 1;       /* skip errorhandler's own CallInfo (level 0) */
    lua_Debug ar;

    if (msg != NULL) {
        luaL_addstring(buf, msg);
        luaL_addchar(buf, '\n');
    }
    luaL_addstring(buf, "stack traceback:");

    st.frames = frames;
    st.n = 0;
    st.cap = TITAN_MAX_NATIVE;
    titan_capture_native(&st);

    /* Drain the deepest native Titan run (the error site) before any CallInfo
    ** so the innermost Titan frames lead. */
    while (ni < st.n) {
        int was_entry = frames[ni].is_entry;
        titan_bt_addframe(buf, &wrote_any, frames[ni].text);
        ni++;
        if (was_entry) break;
    }

    while (lua_getstack(L, level++, &ar)) {
        lua_getinfo(L, "Slnt", &ar);
        if (ar.what != NULL && ar.what[0] == 'C') {
            /* A C-level CallInfo: a Titan entry wrapper or a Lua C-function.
            ** Splice the next native Titan run (up to & including its sentinel)
            ** for the Titan-entry case. */
            int drained = 0;
            while (ni < st.n) {
                int was_entry = frames[ni].is_entry;
                titan_bt_addframe(buf, &wrote_any, frames[ni].text);
                ni++;
                drained = 1;
                if (was_entry) break;
            }
            /* If we drained a sentinel-terminated run, this CallInfo was the
            ** Titan entry wrapper, already represented by the native frames; do
            ** not also emit a [C] line for it. Otherwise it is a genuine Lua
            ** C-function: name it. */
            if (!drained) {
                char line[512], nm[256];
                snprintf(line, sizeof(line), "\t%s: in %s",
                         ar.short_src, titan_funcname(&ar, nm, sizeof(nm)));
                titan_bt_addframe(buf, &wrote_any, line);
            }
        } else {
            /* A pure-Lua activation: src:line: in name. */
            char line[512], nm[256];
            const char *fn = titan_funcname(&ar, nm, sizeof(nm));
            if (ar.currentline > 0) {
                snprintf(line, sizeof(line), "\t%s:%d: in %s",
                         ar.short_src, ar.currentline, fn);
            } else {
                snprintf(line, sizeof(line), "\t%s: in %s",
                         ar.short_src, fn);
            }
            titan_bt_addframe(buf, &wrote_any, line);
        }
        if (ar.istailcall) {
            titan_bt_addframe(buf, &wrote_any, "\t(...tail calls...)");
        }
    }

    /* Defensive: any native Titan frames the CallInfo walk did not consume
    ** (e.g. native depth exceeding the Lua-visible boundaries) still appear. */
    while (ni < st.n) {
        titan_bt_addframe(buf, &wrote_any, frames[ni].text);
        ni++;
    }
}
#else
void titan_invalidate_backtrace_state(void) { /* no cached state to reset */ }
#endif

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
            path = TITAN_PATH_DEFAULT;
            lua_pushstring(L, path);
        } else {
            path = luaL_gsub(L, path, ";;", ";\1;");
            path = luaL_gsub(L, path, "\1", TITAN_PATH_DEFAULT);
            lua_remove(L, -2); /* remove result from 1st 'gsub' */
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
                titan_invalidate_backtrace_state();
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

  /* Regenerate the slot. luaL_Buffer lives on the stack from luaL_buffinit on
  ** and must stay at the top while in use, so push everything else first. */
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  luaL_tolstring(L, top, NULL);
  lua_pushliteral(L, "\n");
  luaL_Buffer buf;
  luaL_buffinit(L, &buf);
#ifdef TITAN_HAVE_LIBBACKTRACE
  /* ONE intermingled, innermost->outer trace (plan A.2): the CallInfo chain
  ** supplies every Lua frame, libbacktrace supplies the Titan native frames
  ** spliced at the entry-wrapper boundaries. No separate "C traceback:" section,
  ** no collapsed [Lua] marker. */
  titan_push_unified_trace(L, &buf, NULL);
#else
  /* Fallback (no libbacktrace, e.g. musl/Alpine): the Lua-side traceback only,
  ** plus an execinfo C traceback with no DWARF line info. Two sections, since
  ** without libbacktrace we cannot splice Titan frames into the Lua trace.
  ** luaL_traceback pushes its own string; add it to the buffer immediately. */
  luaL_traceback(L, L, NULL, 1);
  luaL_addvalue(&buf);
  {
    int nested = 0;
    void *nbuf[255];
    const int calls = backtrace(nbuf, sizeof(nbuf) / sizeof(void *));
    char **bt = backtrace_symbols(nbuf, calls);
    luaL_addstring(&buf, "\nC traceback:\n");
    for (int i = 0; i < calls; i++) {
      if (nested++) { luaL_addchar(&buf, '\n'); }
      luaL_addstring(&buf, bt[i]);
    }
    free(bt);
  }
#endif
  luaL_pushresult(&buf);
  lua_concat(L, 3);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_settop(L, top);
  return 1;
}
