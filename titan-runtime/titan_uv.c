#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include "lobject.h"
#include "lua.h"

#include <uv.h>

#include "titan.h"
#include "titan/uv.h"

typedef void (*titan_uv_dispatch_func)(lua_State *L, Udata *_mod, CClosure *_fn,
                                       Udata *owner, lua_Integer event_kind,
                                       lua_Integer result, size_t size,
                                       void *pointer);

/*
 * The Runtime-owned owner/resource graph strongly roots owner while libuv can
 * call us.  Its fixed five-slot layout places the main thread and dispatcher
 * at the indices below; those fields are trusted in exactly the same way as
 * the fixed coroutine-owner fields read by titan_coro_entry.
 */
static void titan_uvshim_dispatch(Udata *owner, lua_Integer event_kind,
                                  lua_Integer result, size_t size,
                                  void *pointer) {
  lua_State *L = thvalue(&owner->uv[TITAN_UV_OWNER_MAIN_THREAD_C_INDEX].uv);
  CClosure *dispatcher =
      clCvalue(&owner->uv[TITAN_UV_OWNER_DISPATCHER_C_INDEX].uv);
  Udata *M = uvalue(&dispatcher->upvalue[0]);
  titan_uv_dispatch_func dispatch =
      titan_cast_func(titan_uv_dispatch_func, pvalue(&dispatcher->upvalue[2]));

  /* Direct native Titan entry: the trusted dispatcher owns its outer catch. */
  dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
}

void titan_uvshim_signal_cb(uv_signal_t *signal, int signum) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)signal);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SIGNAL, signum, 0, NULL);
}

void titan_uvshim_process_exit_cb(uv_process_t *process, int64_t exit_status,
                                  int term_signal) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)process);
  size_t signal_size;

  assert(term_signal >= 0);
  signal_size = (size_t)term_signal;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_PROCESS_EXIT,
                        (lua_Integer)exit_status, signal_size, NULL);
}

void titan_uvshim_getaddrinfo_cb(uv_getaddrinfo_t *req, int status,
                                 struct addrinfo *result) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_GETADDRINFO, status, 0, result);
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

void titan_uvshim_alloc_cb(uv_handle_t *handle, size_t suggested_size,
                           uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  assert(buf != NULL);
  *buf = uv_buf_init(NULL, 0);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_STREAM_ALLOC, 0, suggested_size,
                        buf);
}

void titan_uvshim_read_cb(uv_stream_t *stream, ssize_t nread,
                          const uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)stream);
  (void)buf;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_STREAM_READ, (lua_Integer)nread,
                        0, NULL);
}

void titan_uvshim_connection_cb(uv_stream_t *server, int status) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)server);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_CONNECTION, status, 0, NULL);
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
