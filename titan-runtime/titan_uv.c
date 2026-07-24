#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lobject.h"
#include "lua.h"

#include <uv.h>

#include "titan.h"
#include "titan/uv.h"

/* C99-compatible compile-time assertions for the public 1-based/0-based map. */
#define TITAN_UV_STATIC_ASSERT(name, condition)                                \
  typedef char titan_uv_static_assert_##name[(condition) ? 1 : -1]

TITAN_UV_STATIC_ASSERT(native_slot,
                       TITAN_UV_OWNER_NATIVE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_NATIVE_C_INDEX);
TITAN_UV_STATIC_ASSERT(storage_slot,
                       TITAN_UV_OWNER_STORAGE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_STORAGE_C_INDEX);
TITAN_UV_STATIC_ASSERT(main_thread_slot,
                       TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_MAIN_THREAD_C_INDEX);
TITAN_UV_STATIC_ASSERT(dispatcher_slot,
                       TITAN_UV_OWNER_DISPATCHER_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_DISPATCHER_C_INDEX);
TITAN_UV_STATIC_ASSERT(metadata_slot,
                       TITAN_UV_OWNER_METADATA_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_METADATA_C_INDEX);
TITAN_UV_STATIC_ASSERT(buffer_slot,
                       TITAN_UV_OWNER_BUFFER_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_BUFFER_C_INDEX);
TITAN_UV_STATIC_ASSERT(slot_count,
                       (int)TITAN_UV_OWNER_LUA_SLOT_COUNT ==
                           (int)TITAN_UV_OWNER_C_INDEX_COUNT);
TITAN_UV_STATIC_ASSERT(fs_result_fits_lua_integer,
                       sizeof(ssize_t) <= sizeof(lua_Integer));
TITAN_UV_STATIC_ASSERT(process_exit_status_fits_lua_integer,
                       sizeof(int64_t) <= sizeof(lua_Integer));
TITAN_UV_STATIC_ASSERT(process_signal_fits_size,
                       sizeof(int) <= sizeof(size_t));
TITAN_UV_STATIC_ASSERT(process_pid_fits_int64,
                       sizeof(uv_pid_t) <= sizeof(int64_t));
TITAN_UV_STATIC_ASSERT(unix_uv_file_is_int,
                       sizeof(uv_file) == sizeof(int));

struct titan_uvshim_address_alignment_probe {
  char byte;
  titan_uvshim_address address;
};

struct titan_uvshim_sockaddr_alignment_probe {
  char byte;
  struct sockaddr_storage address;
};

TITAN_UV_STATIC_ASSERT(address_storage_size,
                       sizeof(titan_uvshim_address) >=
                           sizeof(struct sockaddr_storage));
TITAN_UV_STATIC_ASSERT(address_storage_alignment,
                       offsetof(struct titan_uvshim_address_alignment_probe,
                                address) >=
                           offsetof(struct titan_uvshim_sockaddr_alignment_probe,
                                    address));

typedef void (*titan_uv_dispatch_func)(lua_State *L, Udata *_mod,
                                       CClosure *_fn, Udata *owner,
                                       lua_Integer event_kind,
                                       lua_Integer result, size_t size,
                                       void *pointer);

/*
 * The Runtime-owned owner/resource graph strongly roots owner while libuv can
 * call us.  These fixed fields are therefore trusted in exactly the same way
 * as the four fixed coroutine-owner fields read by titan_coro_entry.
 */
static void titan_uvshim_dispatch(Udata *owner, lua_Integer event_kind,
                                  lua_Integer result, size_t size,
                                  void *pointer) {
  lua_State *L =
      thvalue(&owner->uv[TITAN_UV_OWNER_MAIN_THREAD_C_INDEX].uv);
  CClosure *dispatcher =
      clCvalue(&owner->uv[TITAN_UV_OWNER_DISPATCHER_C_INDEX].uv);
  Udata *M = uvalue(&dispatcher->upvalue[0]);
  titan_uv_dispatch_func dispatch =
      titan_cast_func(titan_uv_dispatch_func,
                      pvalue(&dispatcher->upvalue[2]));

  /* Direct native Titan entry: the trusted dispatcher owns its outer catch. */
  dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
}

void titan_uvshim_signal_cb(uv_signal_t *signal, int signum) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)signal);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SIGNAL, signum, 0, NULL);
}

void titan_uvshim_process_exit_cb(uv_process_t *process,
                                  int64_t exit_status,
                                  int term_signal) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)process);
  size_t signal_size;

  assert(term_signal >= 0);
  signal_size = (size_t)term_signal;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_PROCESS_EXIT,
                        (lua_Integer)exit_status, signal_size, NULL);
}

void titan_uvshim_getaddrinfo_cb(uv_getaddrinfo_t *req,
                                 int status,
                                 struct addrinfo *result) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_GETADDRINFO, status, 0,
                        result);
}

void titan_uvshim_connect_cb(uv_connect_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_CONNECT, status, 0, NULL);
}

void titan_uvshim_write_cb(uv_write_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_WRITE, status, 0, NULL);
}

void titan_uvshim_shutdown_cb(uv_shutdown_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SHUTDOWN, status, 0, NULL);
}

void titan_uvshim_alloc_cb(uv_handle_t *handle,
                           size_t suggested_size,
                           uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  assert(buf != NULL);
  *buf = uv_buf_init(NULL, 0);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_STREAM_ALLOC, 0,
                        suggested_size, buf);
}

void titan_uvshim_read_cb(uv_stream_t *stream,
                          ssize_t nread,
                          const uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)stream);
  (void)buf;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_STREAM_READ,
                        (lua_Integer)nread, 0, NULL);
}

void titan_uvshim_connection_cb(uv_stream_t *server, int status) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)server);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_CONNECTION, status, 0, NULL);
}

int titan_uvshim_ignore_sigpipe_if_default(void) {
  struct sigaction current;
  struct sigaction ignore;
  if (sigaction(SIGPIPE, NULL, &current) != 0)
    return uv_translate_sys_error(errno);
  if (current.sa_handler != SIG_DFL)
    return 0;
  memset(&ignore, 0, sizeof(ignore));
  ignore.sa_handler = SIG_IGN;
  if (sigemptyset(&ignore.sa_mask) != 0 ||
      sigaction(SIGPIPE, &ignore, NULL) != 0)
    return uv_translate_sys_error(errno);
  return 0;
}

void titan_uvshim_timer_cb(uv_timer_t *timer) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)timer);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_TIMER, 0, 0, NULL);
}

void titan_uvshim_close_cb(uv_handle_t *handle) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_HANDLE_CLOSE, 0, 0, NULL);
}

void titan_uvshim_fs_cb(uv_fs_t *req) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  lua_Integer result = (lua_Integer)uv_fs_get_result(req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_FS, result, 0, NULL);
}
