require "titan-compiler.coder.names"
local coder = require("titan-compiler.coder.core").coder
local util = require "titan-compiler.util"
local M = {}

M.error_helpers = [[
/* Shared by native main, browser bootstrap/main and titan.browser's protected
 * formatter. Needs two temporary API slots beyond the indexed, rooted error.
 * May raise; callers choose protection and stack cleanup for their context. */
TValue titan_entry_error_message(lua_State *L, int idx) {
    int result;
    idx = lua_absindex(L, idx);
    result = idx;
    if (lua_tolstring(L, idx, NULL) == NULL) {
        if (!luaL_callmeta(L, idx, "__tostring") || lua_type(L, -1) != LUA_TSTRING) {
            lua_pushfstring(L, "(error object is a %s value)",
                           luaL_typename(L, idx));
        }
        result = -1;
    }
    return lua_totvalue(L, result);
}

static const char *strip_bootstrap_prefix(const char *message, size_t *len) {
    static const char prefix[] = "[string \"local arg = ...;...\"]:3: ";
    const size_t prefix_len = sizeof(prefix) - 1;
    if (len) {
        while (*len >= prefix_len && memcmp(message, prefix, prefix_len) == 0) {
            message += prefix_len;
            *len -= prefix_len;
        }
    } else {
        while (strncmp(message, prefix, prefix_len) == 0) {
            message += prefix_len;
        }
    }
    return message;
}
]]

-- Every image has one persistent protected owner state. Protocol-only images
-- use an empty initializer; a Titan image supplies its module bootstrap.
local template = [[
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"
#include "titan/browser.h"
#include <errno.h>
#include <wasi/api.h>
#include <emscripten/syscalls.h>

/* libc requires these exact symbols even in images without Titan modules.
 * The launcher owns the filesystem-free image; only output crosses to JS. */
__wasi_errno_t __wasi_fd_write(__wasi_fd_t fd, const __wasi_ciovec_t *iovs,
        size_t iovs_len, __wasi_size_t *nwritten) {
    if (fd != 1 && fd != 2) return __WASI_ERRNO_BADF;
    __wasi_size_t total = 0;
    for (size_t i = 0; i < iovs_len; i++) {
        if (iovs[i].buf_len)
            titan_browser_host_output(fd, iovs[i].buf, iovs[i].buf_len);
        total += iovs[i].buf_len;
    }
    *nwritten = total;
    return __WASI_ERRNO_SUCCESS;
}
__wasi_errno_t __wasi_fd_read(__wasi_fd_t fd, const __wasi_iovec_t *iovs, size_t iovs_len, __wasi_size_t *nread) { return __WASI_ERRNO_NOSYS; }
__wasi_errno_t __wasi_fd_close(__wasi_fd_t fd) { return fd <= 2 ? __WASI_ERRNO_SUCCESS : __WASI_ERRNO_BADF; }
__wasi_errno_t __wasi_fd_seek(__wasi_fd_t fd, __wasi_filedelta_t offset, __wasi_whence_t whence, __wasi_filesize_t *newoffset) { return __WASI_ERRNO_SPIPE; }
int __syscall_openat(int dirfd, const char *path, int flags, ...) { return -ENOSYS; }
int __syscall_unlinkat(int dirfd, const char *path, int flags) { return -ENOSYS; }
int __syscall_renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath) { return -ENOSYS; }
int __syscall_rmdir(const char *path) { return -ENOSYS; }
int __syscall_stat64(const char *path, struct stat *buf) { return -ENOSYS; }
int __syscall_lstat64(const char *path, struct stat *buf) { return -ENOSYS; }
int __syscall_fstat64(int fd, struct stat *buf) { return -ENOSYS; }
int __syscall_newfstatat(int dirfd, const char *path, struct stat *buf, int flags) { return -ENOSYS; }
int __syscall_getcwd(char *buf, size_t size) { return -ENOSYS; }
int __syscall_readlinkat(int dirfd, const char *path, char *buf, size_t bufsize) { return -ENOSYS; }
int __syscall_ioctl(int fd, int request, ...) { return -ENOSYS; }
int __syscall_fcntl64(int fd, int cmd, ...) { return -ENOSYS; }
int __syscall_dup3(int oldfd, int newfd, int flags) { return -ENOSYS; }
int _emscripten_system(const char *command) { return command ? -ENOSYS : 0; }

struct titan_browser_arguments {
    int argc;
    const unsigned char *const *argv;
    const size_t *lengths;
};

extern int $INVOKE_FN(
    unsigned long long operation_id, unsigned int state, unsigned int slot,
    unsigned int generation, unsigned int argc,
    const void *args) __attribute__((weak));
extern int $RELEASE_FN(unsigned int state, unsigned int slot,
    unsigned int generation) __attribute__((weak));
extern int $CALL_SYNC_FN(const void *identity, unsigned int argc, const void *args,
    void *result) __attribute__((weak));
extern int $CALLBACK_ENTER_FN(unsigned int state, void *frame) __attribute__((weak));
extern void $CALLBACK_LEAVE_FN(void *frame) __attribute__((weak));

static lua_State *titan_browser_owner;
/* Images without titan.browser use a launcher-owned bare token. */
static uint32_t titan_browser_owner_token;
static int titan_browser_owner_ready;

/* titan.browser compares its state's main thread with this once, at module
 * initialization: only the launcher's owner state may drive the instance. */
lua_State *titan_browser_owner_thread(void) { return titan_browser_owner; }

$ERROR_HELPERS

int titan_browser_invalid_entry(uint64_t id, uint32_t operation, const char *message) {
    titan_browser_completion completion = {0};
    completion.operation_id = id;
    completion.operation = operation;
    completion.status = TITAN_BROWSER_STATE;
    completion.application_status = 1;
    completion.message = (const unsigned char *)message;
    completion.message_length = (uint32_t)strlen(message);
    fflush(stdout);
    fflush(stderr);
    titan_browser_complete(&completion);
    return 0;
}

static int titan_browser_error_worker(lua_State *L) {
    TValue message = titan_entry_error_message(L, 1);
    size_t len = tsslen(tsvalue(&message));
    const char *msg = strip_bootstrap_prefix(getstr(tsvalue(&message)), &len);
    lua_pushlstring(L, msg, len);
    return 1;
}

static void titan_browser_complete_failure(lua_State *L,
        titan_browser_completion *completion) {
    static const unsigned char conversion_error[] =
        "error while reporting browser failure";
    size_t length = 0, trace_length = 0;
    const char *raw = NULL, *trace = NULL;
    const unsigned char *message;
    int error_index = lua_gettop(L), trace_index = error_index + 1;
    completion->status = TITAN_BROWSER_TITAN_ERROR;
    completion->application_status = 1;
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    lua_pushcfunction(L, titan_browser_error_worker);
    lua_pushvalue(L, error_index);
    if (lua_pcall(L, 1, 1, 0) == LUA_OK)
        raw = lua_tolstring(L, -1, &length);
    titan_unwind_clear_trace(L);
    lua_pushvalue(L, trace_index);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY);
    if (lua_type(L, trace_index) == LUA_TSTRING)
        trace = lua_tolstring(L, trace_index, &trace_length);
    if (!raw) {
        message = conversion_error;
        length = sizeof(conversion_error) - 1;
    } else {
        message = (const unsigned char *)raw;
    }
    completion->message = message;
    completion->message_length = (uint32_t)length;
    completion->trace = (const unsigned char *)trace;
    completion->trace_length = trace ? (uint32_t)trace_length : 0;
    if (message == conversion_error) {
        fwrite(message, 1, length, stderr);
        fputc('\n', stderr);
    } else {
        fputs("$PROGNAME: ", stderr);
        fwrite(message, 1, length, stderr);
        fputc('\n', stderr);
        if (trace) {
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
    }
    fflush(stdout);
    fflush(stderr);
    titan_browser_complete(completion);
}

static int titan_browser_protected_entry(uint64_t id, uint32_t operation,
        lua_State *L, lua_CFunction worker, void *context, int main_result) {
    int top = lua_gettop(L);
    titan_browser_completion completion = {0};
    completion.operation_id = id;
    completion.operation = operation;
    /* Owner state enters at top == 0 with LUA_MINSTACK slots pre-allocated. */
    lua_pushcfunction(L, errorhandler);
    lua_pushcfunction(L, worker);
    lua_pushlightuserdata(L, context);
    if (lua_pcall(L, 1, main_result, top + 1) != LUA_OK) {
        titan_browser_complete_failure(L, &completion);
    } else {
        if (main_result) {
            uint32_t low = (uint32_t)(lua_Unsigned)lua_tointeger(L, -1);
            completion.application_status = low <= INT32_MAX ? (int32_t)low :
                -1 - (int32_t)(UINT32_MAX - low);
        }
        fflush(stdout);
        fflush(stderr);
        titan_browser_complete(&completion);
    }
    lua_settop(L, top);
    return 0;
}

$DECLARATIONS
$INITIALIZER
$WORKER

static int titan_browser_initialize_entry(lua_State *L) {
    if (!$INVOKE_FN) {
        titan_browser_owner_token = titan_browser_host_state_open(NULL);
        if (!titan_browser_owner_token)
            luaL_error(L, "browser state identity exhausted");
    }
    lua_settop(L, 0);
    titan_browser_initialize_worker(L);
    titan_browser_owner_ready = 1;
    return 0;
}

int titan_browser_initialize(uint64_t operation_id) {
    if (!titan_browser_entry_allowed(operation_id, TITAN_BROWSER_INITIALIZE))
        return -1;
    titan_browser_owner = luaL_newstate();
    if (!titan_browser_owner) {
        titan_browser_completion completion = {0};
        static const unsigned char message[] = "not enough memory for state";
        completion.operation_id = operation_id;
        completion.operation = TITAN_BROWSER_INITIALIZE;
        completion.status = TITAN_BROWSER_MEMORY;
        completion.application_status = $STATE_STATUS;
        completion.message = message;
        completion.message_length = sizeof(message) - 1;
        fflush(stdout);
        fflush(stderr);
        titan_browser_complete(&completion);
        return 0;
    }
    return titan_browser_protected_entry(operation_id, TITAN_BROWSER_INITIALIZE,
        titan_browser_owner, titan_browser_initialize_entry, NULL, 0);
}

int titan_browser_entry(uint64_t operation_id, int argc,
        const unsigned char *const *argv, const size_t *lengths) {
    struct titan_browser_arguments arguments = {argc, argv, lengths};
    if (!titan_browser_entry_allowed(operation_id, TITAN_BROWSER_MAIN))
        return -1;
    if (!titan_browser_owner || !titan_browser_owner_ready)
        return titan_browser_invalid_entry(operation_id, TITAN_BROWSER_MAIN,
            "browser main is unavailable");
    return titan_browser_protected_entry(operation_id, TITAN_BROWSER_MAIN,
        titan_browser_owner, titan_browser_worker, &arguments, 1);
}

int titan_browser_invoke(uint64_t operation_id, uint32_t state, uint32_t slot,
        uint32_t generation, uint32_t argc, const titan_browser_value *args) {
    return $INVOKE_FN
        ? $INVOKE_FN(operation_id, state, slot, generation, argc, args)
        : (!titan_browser_entry_allowed(operation_id, TITAN_BROWSER_INVOKE) ? -1
            : titan_browser_invalid_entry(operation_id, TITAN_BROWSER_INVOKE,
                  "browser state is closed, closing or uninitialized"));
}

int titan_browser_release_callable(uint32_t state, uint32_t slot, uint32_t generation) {
    return $RELEASE_FN ? $RELEASE_FN(state, slot, generation) : TITAN_BROWSER_STATE;
}

/* C-callable synchronous callback entries for authored C in the image. */
int titan_browser_call_sync(const titan_browser_identity *callable, uint32_t argc,
        const titan_browser_value *args, titan_browser_sync_result *result) {
    if ($CALL_SYNC_FN) return $CALL_SYNC_FN(callable, argc, args, result);
    if (result) result->status = TITAN_BROWSER_STATE;
    return TITAN_BROWSER_STATE;
}

int titan_browser_callback_enter(uint32_t state, titan_browser_callback_frame *frame) {
    return $CALLBACK_ENTER_FN ? $CALLBACK_ENTER_FN(state, frame) : TITAN_BROWSER_STATE;
}

void titan_browser_callback_leave(titan_browser_callback_frame *frame) {
    if ($CALLBACK_LEAVE_FN) $CALLBACK_LEAVE_FN(frame);
}

int titan_browser_close(uint64_t operation_id) {
    titan_browser_completion completion = {0};
    if (!titan_browser_entry_allowed(operation_id, TITAN_BROWSER_CLOSE))
        return -1;
    completion.operation_id = operation_id;
    completion.operation = TITAN_BROWSER_CLOSE;
    if (titan_browser_owner) {
        lua_State *L = titan_browser_owner;
        uint32_t token = titan_browser_owner_token;
        titan_browser_owner = NULL;
        titan_browser_owner_token = 0;
        if (token) titan_browser_host_state_closing(token);
        lua_close(L);
        if (token) titan_browser_host_state_closed(token);
    }
    fflush(stdout);
    fflush(stderr);
    titan_browser_complete(&completion);
    return 0;
}
]]

function M.contents(worker, options)
    options = options or {}
    return util.render(template, {
        ERROR_HELPERS = M.error_helpers,
        INVOKE_FN = coder._foreign_func_name("titan.browser", "invoke"),
        RELEASE_FN = coder._foreign_func_name("titan.browser", "release_callable"),
        CALL_SYNC_FN = coder._foreign_func_name("titan.browser", "call_sync"),
        CALLBACK_ENTER_FN = coder._foreign_func_name("titan.browser", "callback_enter"),
        CALLBACK_LEAVE_FN = coder._foreign_func_name("titan.browser", "callback_leave"),
        DECLARATIONS = options.declarations or "",
        INITIALIZER = options.initializer or
            "static int titan_browser_initialize_worker(lua_State *L) { (void)L; return 0; }",
        WORKER = worker, PROGNAME = options.program_name or "titan",
        STATE_STATUS = tostring(options.state_status or 1) })
end
return M
