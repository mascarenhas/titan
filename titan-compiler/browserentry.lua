local util = require "titan-compiler.util"
local M = {}

-- All Titan images, including C-only protocol/control images, share this
-- protected initialization, reporting, Lua-close and libc-drain boundary.
local template = [[
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"

extern void titan_browser_complete(int kind, int status,
    const unsigned char *bytes, size_t length);
extern int titan_browser_entry_allowed(void);
struct titan_browser_arguments {
    int argc;
    const unsigned char *const *argv;
    const size_t *lengths;
};
$DECLARATIONS
$WORKER

static int titan_browser_report(lua_State *L) {
    size_t length, trace_length = 0;
    const char *message = lua_tolstring(L, 1, &length);
    const char *trace;
    static const char prefix[] = "[string \"local arg = ...;...\"]:3: ";
    if (message == NULL) {
        if (!luaL_callmeta(L, 1, "__tostring") || lua_type(L, -1) != LUA_TSTRING)
            lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
        message = lua_tolstring(L, -1, &length);
    }
    while (length >= sizeof(prefix) - 1 && memcmp(message, prefix, sizeof(prefix) - 1) == 0) {
        message += sizeof(prefix) - 1;
        length -= sizeof(prefix) - 1;
    }
    /* Root a length-aware completion string before fetching the trace. Both
    ** owners stay alive throughout reporting, including embedded NUL bytes. */
    lua_pushlstring(L, message, length);
    message = lua_tolstring(L, -1, &length);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    trace = lua_tolstring(L, -1, &trace_length);
    fputs("$PROGNAME: ", stderr);
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
    if (trace != NULL) {
        const char *cursor = trace, *limit = trace + trace_length;
        fputs("stack traceback:", stderr);
        while (cursor < limit) {
            const char *end = memchr(cursor, '\n', (size_t)(limit - cursor));
            size_t count = end ? (size_t)(end - cursor) : (size_t)(limit - cursor);
            fputs("\n\t", stderr);
            fwrite(cursor, 1, count, stderr);
            if (!end) break;
            cursor = end + 1;
        }
        fputc('\n', stderr);
    }
    lua_pop(L, 1);
    return 1;
}

static int titan_browser_active;
static int titan_browser_used;
int titan_browser_entry(int argc, const unsigned char *const *argv,
                         const size_t *lengths) {
    static const unsigned char state_error[] = "not enough memory for state";
    static const unsigned char report_error[] = "error while reporting browser failure";
    static const unsigned char copy_error[] = "not enough memory to copy browser error";
    static const unsigned char stdout_error[] = "cannot flush browser stdout";
    static const unsigned char stderr_error[] = "cannot flush browser stderr";
    struct titan_browser_arguments arguments = { argc, argv, lengths };
    const unsigned char *bytes = NULL;
    unsigned char *owned = NULL;
    size_t length = 0;
    int kind = 0, status = 0, stdout_status, stderr_status;
    lua_State *L;
    if (titan_browser_active) return -1;
    if (titan_browser_used) return -2;
    if (!titan_browser_entry_allowed()) return -1;
    titan_browser_active = titan_browser_used = 1;
    L = luaL_newstate();
    /* A fresh state already provides LUA_MINSTACK slots. The three pushes
    ** establishing protection cannot allocate and need no stack growth.
    ** Keep allocation and raising reservations inside the protected call. */
    if (L == NULL) {
        kind = 1; status = $STATE_STATUS;
        bytes = state_error; length = sizeof(state_error) - 1;
    } else {
        lua_pushcfunction(L, errorhandler);
        lua_pushcfunction(L, titan_browser_worker);
        lua_pushlightuserdata(L, &arguments);
        if (lua_pcall(L, 1, 1, 1) == LUA_OK) {
            /* Defined low-32-bit signed interpretation, including on native
            ** hosts used by focused null-backend/entry fixtures. */
            uint32_t low = (uint32_t)(lua_Unsigned)lua_tointeger(L, -1);
            status = low <= INT32_MAX ? (int)low : -1 - (int)(UINT32_MAX - low);
        } else {
            kind = 1; status = 1;
            /* Separate pcall deliberately has no errorhandler: conversion may
            ** throw, but must never recapture/overwrite the original trace. */
            lua_pushcfunction(L, titan_browser_report);
            lua_pushvalue(L, -2);
            if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
                bytes = report_error; length = sizeof(report_error) - 1;
                fwrite(bytes, 1, length, stderr); fputc('\n', stderr);
            } else {
                const char *message = lua_tolstring(L, -1, &length);
                owned = (unsigned char *)malloc(length ? length : 1);
                if (owned == NULL) {
                    bytes = copy_error; length = sizeof(copy_error) - 1;
                } else {
                    if (length) memcpy(owned, message, length);
                    bytes = owned;
                }
            }
        }
    }
    if (L != NULL) lua_close(L);
    stdout_status = fflush(stdout);
    stderr_status = fflush(stderr);  /* Always attempt both, preserving first error. */
    if (kind == 0 && (stdout_status != 0 || stderr_status != 0)) {
        kind = 1; status = 1;
        bytes = stdout_status != 0 ? stdout_error : stderr_error;
        length = stdout_status != 0 ? sizeof(stdout_error) - 1 : sizeof(stderr_error) - 1;
    }
    titan_browser_complete(kind, status, bytes, length);
    free(owned);  /* completion synchronously copies the payload */
    titan_browser_active = 0;
    return 0;     /* admission only; never the Titan result */
}
]]

function M.contents(worker, options)
    options = options or {}
    return util.render(template, { DECLARATIONS = options.declarations or "",
        WORKER = worker, PROGNAME = options.program_name or "titan",
        STATE_STATUS = tostring(options.state_status or 1) })
end

return M
