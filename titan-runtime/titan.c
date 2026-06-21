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

/* Classify a native frame's DWARF source filename:
**   0 = show it (a user/Titan .titan or .c file),
**   1 = a lua-5.5.0 interpreter source frame (collapse to a single [Lua]),
**   2 = a titan-runtime frame (hide), or an unsymbolized frame (drop). */
static int titan_frame_class(const char *filename) {
    if (filename == NULL) return 2;             /* unsymbolized libc/etc.: drop */
    if (strstr(filename, "lua-5.5.0/src/")) return 1;
    if (strstr(filename, "titan-runtime/")) return 2;
    return 0;
}

typedef struct {
    lua_State *L;
    luaL_Buffer *buf;
    int wrote_any;      /* emitted at least one frame (controls leading '\n') */
    int in_lua_run;     /* currently inside a collapsed [Lua] run */
} titan_bt_ctx;

static void titan_bt_addframe(titan_bt_ctx *ctx, const char *text) {
    if (ctx->wrote_any) luaL_addchar(ctx->buf, '\n');
    luaL_addstring(ctx->buf, text);
    ctx->wrote_any = 1;
}

static int titan_bt_full_cb(void *data, uintptr_t pc, const char *filename,
                            int lineno, const char *function) {
    titan_bt_ctx *ctx = (titan_bt_ctx *)data;
    int cls = titan_frame_class(filename);
    if (cls == 1) {
        /* Collapse a contiguous run of interpreter frames to one marker. */
        if (!ctx->in_lua_run) {
            titan_bt_addframe(ctx, "\t[Lua]");
            ctx->in_lua_run = 1;
        }
        return 0;
    }
    ctx->in_lua_run = 0;
    if (cls == 2) return 0;  /* hidden: titan-runtime or unsymbolized */
    /* A user/Titan frame: "\t<file>:<line>: in <function>". Without #line
    ** (Phase 1) the file is the generated .c and the function is the C symbol;
    ** that is expected and still useful. */
    {
        char line[512];
        const char *base = titan_basename(filename);
        snprintf(line, sizeof(line), "\t%s:%d: in %s",
                 base ? base : "?", lineno,
                 function ? function : "?");
        titan_bt_addframe(ctx, line);
    }
    return 0;
}

/* Append the filtered native (libbacktrace) trace to the open luaL_Buffer. */
static void titan_push_native_trace(lua_State *L, luaL_Buffer *buf) {
    if (titan_bt_state == NULL) {
        titan_bt_state = backtrace_create_state(NULL, 1, titan_bt_error, NULL);
    }
    if (titan_bt_state == NULL) return;
    titan_bt_ctx ctx;
    ctx.L = L;
    ctx.buf = buf;
    ctx.wrote_any = 0;
    ctx.in_lua_run = 0;
    /* skip=1: drop errorhandler's own frame. */
    backtrace_full(titan_bt_state, 1, titan_bt_full_cb, titan_bt_error, &ctx);
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
  luaL_traceback(L, L, NULL, 0);
  lua_pushliteral(L, "\nC traceback:\n");
  luaL_Buffer buf;
  luaL_buffinit(L, &buf);
#ifdef TITAN_HAVE_LIBBACKTRACE
  /* Merge native (Titan/C) frames captured by libbacktrace: show user/Titan
  ** files, collapse interpreter frames to a single [Lua], hide runtime and
  ** unsymbolized frames. */
  titan_push_native_trace(L, &buf);
#else
  /* Fallback: execinfo with no DWARF line info (also covers musl/Alpine). */
  {
    void *nbuf[255];
    const int calls = backtrace(nbuf, sizeof(nbuf) / sizeof(void *));
    char **bt = backtrace_symbols(nbuf, calls);
    for (int i = 0; i < calls; i++) {
      if (i > 0) { luaL_addchar(&buf, '\n'); }
      luaL_addstring(&buf, bt[i]);
    }
    free(bt);
  }
#endif
  luaL_pushresult(&buf);
  lua_concat(L, 5);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_settop(L, top);
  return 1;
}
