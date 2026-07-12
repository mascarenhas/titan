#include <limits.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>

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
TITAN_UV_STATIC_ASSERT(module_slot,
                       TITAN_UV_OWNER_MODULE_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_MODULE_C_INDEX);
TITAN_UV_STATIC_ASSERT(dispatcher_slot,
                       TITAN_UV_OWNER_DISPATCHER_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_DISPATCHER_C_INDEX);
TITAN_UV_STATIC_ASSERT(root_slot,
                       TITAN_UV_OWNER_ROOT_LUA_SLOT - 1 ==
                           TITAN_UV_OWNER_ROOT_C_INDEX);
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
 * The Runtime pending/resource table strongly roots owner while libuv can call
 * us.  These fixed fields are therefore trusted in exactly the same way as the
 * four fixed coroutine-owner fields read by titan_coro_entry.
 */
static void titan_uvshim_dispatch(Udata *owner, lua_Integer event_kind,
                                  lua_Integer result, size_t size,
                                  void *pointer) {
  lua_State *L =
      thvalue(&owner->uv[TITAN_UV_OWNER_MAIN_THREAD_C_INDEX].uv);
  Udata *M = uvalue(&owner->uv[TITAN_UV_OWNER_MODULE_C_INDEX].uv);
  CClosure *dispatcher =
      clCvalue(&owner->uv[TITAN_UV_OWNER_DISPATCHER_C_INDEX].uv);
  titan_uv_dispatch_func dispatch =
      titan_cast_func(titan_uv_dispatch_func,
                      pvalue(&dispatcher->upvalue[2]));

  /* Direct native Titan entry: the trusted dispatcher owns its outer catch. */
  dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
}

static void titan_uvshim_signal_cb(uv_signal_t *signal, int signum) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)signal);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SIGNAL, signum, 0, NULL);
}

static void titan_uvshim_process_exit_cb(uv_process_t *process,
                                         int64_t exit_status,
                                         int term_signal) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)process);
  size_t signal_size = term_signal >= 0 ? (size_t)term_signal : 0;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_PROCESS_EXIT,
                        (lua_Integer)exit_status, signal_size, NULL);
}

static void titan_uvshim_getaddrinfo_cb(uv_getaddrinfo_t *req,
                                        int status,
                                        struct addrinfo *result) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_GETADDRINFO, status, 0,
                        result);
}

static void titan_uvshim_connect_cb(uv_connect_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_CONNECT, status, 0, NULL);
}

static void titan_uvshim_write_cb(uv_write_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_WRITE, status, 0, NULL);
}

static void titan_uvshim_shutdown_cb(uv_shutdown_t *req, int status) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SHUTDOWN, status, 0, NULL);
}

static void titan_uvshim_alloc_cb(uv_handle_t *handle,
                                  size_t suggested_size,
                                  uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  const TValue *slot = &owner->uv[TITAN_UV_OWNER_BUFFER_C_INDEX].uv;
  Udata *storage;

  (void)suggested_size;
  if (!ttisfulluserdata(slot)) {
    *buf = uv_buf_init(NULL, 0);
    return;
  }
  storage = uvalue(slot);
  if (storage->len > UINT_MAX) {
    *buf = uv_buf_init(NULL, 0);
    return;
  }
  *buf = uv_buf_init((char *)getudatamem(storage),
                     (unsigned int)storage->len);
}

static void titan_uvshim_read_cb(uv_stream_t *stream,
                                 ssize_t nread,
                                 const uv_buf_t *buf) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)stream);
  (void)buf;
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_STREAM_READ,
                        (lua_Integer)nread, 0, NULL);
}

static void titan_uvshim_connection_cb(uv_stream_t *server, int status) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)server);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_CONNECTION, status, 0, NULL);
}

static const char *titan_uvshim_format_port(int port, char service[6]) {
  char *cursor = service + 5;
  *cursor = '\0';
  do {
    *--cursor = (char)('0' + port % 10);
    port /= 10;
  } while (port != 0);
  return cursor;
}

int titan_uvshim_getaddrinfo_start(uv_loop_t *loop,
                                   uv_getaddrinfo_t *req,
                                   void *data,
                                   const char *node,
                                   int port) {
  struct addrinfo hints;
  char service[6];

  if (loop == NULL || req == NULL || data == NULL || node == NULL ||
      port < 0 || port > 65535) {
    return UV_EINVAL;
  }
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
#ifdef AI_NUMERICSERV
  hints.ai_flags = AI_NUMERICSERV;
#endif
  uv_req_set_data((uv_req_t *)req, data);
  return uv_getaddrinfo(loop, req, titan_uvshim_getaddrinfo_cb, node,
                        titan_uvshim_format_port(port, service), &hints);
}

int titan_uvshim_getaddrinfo_cancel(uv_getaddrinfo_t *req) {
  return uv_cancel((uv_req_t *)req);
}

static int titan_uvshim_addrinfo_is_usable(const struct addrinfo *entry) {
  return entry->ai_addr != NULL &&
         (entry->ai_family == AF_INET || entry->ai_family == AF_INET6) &&
         entry->ai_addrlen <= sizeof(struct sockaddr_storage);
}

int64_t titan_uvshim_addrinfo_count(const void *result) {
  const struct addrinfo *entry = (const struct addrinfo *)result;
  int64_t count = 0;

  while (entry != NULL) {
    if (titan_uvshim_addrinfo_is_usable(entry)) {
      if (count == INT64_MAX)
        return UV_EOVERFLOW;
      count++;
    }
    entry = entry->ai_next;
  }
  return count;
}

int titan_uvshim_addrinfo_copy(const void *result,
                               void *address_storage,
                               int64_t capacity) {
  const struct addrinfo *entry = (const struct addrinfo *)result;
  titan_uvshim_address *addresses =
      (titan_uvshim_address *)address_storage;
  int64_t count = 0;

  if (capacity < 0 || (capacity > 0 && addresses == NULL) ||
      (uint64_t)capacity > SIZE_MAX / sizeof(*addresses)) {
    return UV_EINVAL;
  }
  while (entry != NULL) {
    if (titan_uvshim_addrinfo_is_usable(entry)) {
      if (count >= capacity)
        return UV_EOVERFLOW;
      memset(&addresses[count], 0, sizeof(addresses[count]));
      memcpy(addresses[count].bytes, entry->ai_addr, entry->ai_addrlen);
      count++;
    }
    entry = entry->ai_next;
  }
  return count == capacity ? 0 : UV_EINVAL;
}

void titan_uvshim_addrinfo_free(void *result) {
  uv_freeaddrinfo((struct addrinfo *)result);
}

static const struct sockaddr *titan_uvshim_address_at(
    const void *address_storage, int64_t count, int64_t index) {
  const titan_uvshim_address *addresses =
      (const titan_uvshim_address *)address_storage;
  if (addresses == NULL || count <= 0 || index < 0 || index >= count)
    return NULL;
  return (const struct sockaddr *)addresses[index].bytes;
}

int titan_uvshim_tcp_init(uv_loop_t *loop, uv_tcp_t *tcp, void *data) {
  int status;
  if (loop == NULL || tcp == NULL || data == NULL)
    return UV_EINVAL;
  status = uv_tcp_init(loop, tcp);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)tcp, data);
  return status;
}

int titan_uvshim_tcp_is_closing(const uv_tcp_t *tcp) {
  return uv_is_closing((const uv_handle_t *)tcp);
}

void titan_uvshim_tcp_close(uv_tcp_t *tcp) {
  uv_close((uv_handle_t *)tcp, titan_uvshim_close_cb);
}

int titan_uvshim_tcp_close_reset(uv_tcp_t *tcp) {
  if (tcp == NULL)
    return UV_EINVAL;
  return uv_tcp_close_reset(tcp, titan_uvshim_close_cb);
}

int titan_uvshim_tcp_bind(uv_tcp_t *tcp,
                          const void *address_storage,
                          int64_t count,
                          int64_t index) {
  const struct sockaddr *address =
      titan_uvshim_address_at(address_storage, count, index);
  if (tcp == NULL || address == NULL)
    return UV_EINVAL;
  return uv_tcp_bind(tcp, address, 0);
}

int titan_uvshim_tcp_bound_port(const uv_tcp_t *tcp) {
  struct sockaddr_storage address;
  int length = sizeof(address);
  int status;

  if (tcp == NULL)
    return UV_EINVAL;
  status = uv_tcp_getsockname(tcp, (struct sockaddr *)&address, &length);
  if (status < 0)
    return status;
  if (address.ss_family == AF_INET)
    return ntohs(((const struct sockaddr_in *)&address)->sin_port);
  if (address.ss_family == AF_INET6)
    return ntohs(((const struct sockaddr_in6 *)&address)->sin6_port);
  return UV_EAFNOSUPPORT;
}

int titan_uvshim_tcp_listen_backlog_is_valid(int64_t backlog) {
  return backlog > 0 && backlog <= INT_MAX;
}

int titan_uvshim_tcp_listen(uv_tcp_t *tcp, int64_t backlog) {
  if (tcp == NULL || !titan_uvshim_tcp_listen_backlog_is_valid(backlog))
    return UV_EINVAL;
  return uv_listen((uv_stream_t *)tcp, (int)backlog,
                   titan_uvshim_connection_cb);
}

int titan_uvshim_tcp_accept(uv_tcp_t *server, uv_tcp_t *client) {
  if (server == NULL || client == NULL)
    return UV_EINVAL;
  return uv_accept((uv_stream_t *)server, (uv_stream_t *)client);
}

int titan_uvshim_tcp_read_start(uv_tcp_t *tcp) {
  if (tcp == NULL)
    return UV_EINVAL;
  return uv_read_start((uv_stream_t *)tcp, titan_uvshim_alloc_cb,
                       titan_uvshim_read_cb);
}

int titan_uvshim_tcp_read_stop(uv_tcp_t *tcp) {
  if (tcp == NULL)
    return UV_EINVAL;
  return uv_read_stop((uv_stream_t *)tcp);
}

int titan_uvshim_tcp_connect_start(uv_connect_t *req,
                                   uv_tcp_t *tcp,
                                   void *data,
                                   const void *address_storage,
                                   int64_t count,
                                   int64_t index) {
  const struct sockaddr *address =
      titan_uvshim_address_at(address_storage, count, index);
  if (req == NULL || tcp == NULL || data == NULL || address == NULL)
    return UV_EINVAL;
  uv_req_set_data((uv_req_t *)req, data);
  return uv_tcp_connect(req, tcp, address, titan_uvshim_connect_cb);
}

int titan_uvshim_tcp_write_start(uv_write_t *req,
                                 uv_tcp_t *tcp,
                                 void *data,
                                 const void *buffer) {
  if (req == NULL || tcp == NULL || data == NULL || buffer == NULL)
    return UV_EINVAL;
  uv_req_set_data((uv_req_t *)req, data);
  return uv_write(req, (uv_stream_t *)tcp, (const uv_buf_t *)buffer, 1,
                  titan_uvshim_write_cb);
}

int titan_uvshim_tcp_shutdown_start(uv_shutdown_t *req,
                                    uv_tcp_t *tcp,
                                    void *data) {
  if (req == NULL || tcp == NULL || data == NULL)
    return UV_EINVAL;
  uv_req_set_data((uv_req_t *)req, data);
  return uv_shutdown(req, (uv_stream_t *)tcp, titan_uvshim_shutdown_cb);
}

enum { TITAN_UV_LAST_STDIO_FD = 2 };

static int titan_uvshim_pair_contains_stdio(const int pair[2]) {
  return pair[0] <= TITAN_UV_LAST_STDIO_FD ||
         pair[1] <= TITAN_UV_LAST_STDIO_FD;
}

static void titan_uvshim_store_pair(int *storage,
                                    int *count,
                                    const int pair[2]) {
  storage[*count] = pair[0];
  storage[*count + 1] = pair[1];
  *count += 2;
}

int titan_uvshim_stdio_pipes(int *endpoints,
                             int *endpoint_count,
                             int *fillers,
                             int *filler_count) {
  int endpoint_capacity;
  int filler_capacity;
  int pair[2];
  int status;

  if (endpoint_count == NULL || filler_count == NULL)
    return UV_EINVAL;
  endpoint_capacity = *endpoint_count;
  filler_capacity = *filler_count;
  *endpoint_count = 0;
  *filler_count = 0;
  if (endpoints == NULL || fillers == NULL ||
      endpoint_capacity < TITAN_UV_STDIO_ENDPOINT_COUNT ||
      filler_capacity < TITAN_UV_STDIO_FILLER_CAPACITY)
    return UV_EINVAL;

  /*
   * POSIX assigns the lowest available descriptors to each public uv_pipe()
   * call.  Keeping both ends of a low candidate open fills fd 0..2 in at most
   * two pairs when the process descriptor table is not racing.  A third low
   * candidate is still returned to the caller for cleanup, then diagnosed.
   */
  for (;;) {
    status = uv_pipe(pair, 0, UV_NONBLOCK_PIPE);
    if (status < 0)
      return status;
    if (!titan_uvshim_pair_contains_stdio(pair)) {
      titan_uvshim_store_pair(endpoints, endpoint_count, pair);
      break;
    }
    titan_uvshim_store_pair(fillers, filler_count, pair);
    if (*filler_count > TITAN_UV_STDIO_FILLER_CAPACITY - 2)
      return UV_EBUSY;
  }

  status = uv_pipe(pair, UV_NONBLOCK_PIPE, 0);
  if (status < 0)
    return status;
  if (titan_uvshim_pair_contains_stdio(pair)) {
    titan_uvshim_store_pair(fillers, filler_count, pair);
    return UV_EBUSY;
  }
  titan_uvshim_store_pair(endpoints, endpoint_count, pair);

  status = uv_pipe(pair, UV_NONBLOCK_PIPE, 0);
  if (status < 0)
    return status;
  if (titan_uvshim_pair_contains_stdio(pair)) {
    titan_uvshim_store_pair(fillers, filler_count, pair);
    return UV_EBUSY;
  }
  titan_uvshim_store_pair(endpoints, endpoint_count, pair);
  return 0;
}

int titan_uvshim_pipe_init(uv_loop_t *loop,
                           uv_pipe_t *pipe,
                           void *data) {
  int status;
  if (loop == NULL || pipe == NULL || data == NULL)
    return UV_EINVAL;
  status = uv_pipe_init(loop, pipe, 0);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)pipe, data);
  return status;
}

int titan_uvshim_pipe_open(uv_pipe_t *pipe,
                           int *endpoints,
                           int endpoint_count,
                           int index) {
  int *fd;
  int status;
  if (pipe == NULL || endpoints == NULL ||
      endpoint_count != TITAN_UV_STDIO_ENDPOINT_COUNT ||
      index < 0 || index >= endpoint_count)
    return UV_EINVAL;
  if (index != TITAN_UV_STDIO_STDIN_PARENT &&
      index != TITAN_UV_STDIO_STDOUT_PARENT &&
      index != TITAN_UV_STDIO_STDERR_PARENT)
    return UV_EINVAL;
  fd = &endpoints[index];
  if (*fd <= TITAN_UV_LAST_STDIO_FD)
    return UV_EINVAL;
  status = uv_pipe_open(pipe, *fd);
  if (status == 0)
    *fd = -1;
  return status;
}

int titan_uvshim_pipe_read_start(uv_pipe_t *pipe) {
  if (pipe == NULL)
    return UV_EINVAL;
  return uv_read_start((uv_stream_t *)pipe, titan_uvshim_alloc_cb,
                       titan_uvshim_read_cb);
}

int titan_uvshim_pipe_read_stop(uv_pipe_t *pipe) {
  if (pipe == NULL)
    return UV_EINVAL;
  return uv_read_stop((uv_stream_t *)pipe);
}

int titan_uvshim_pipe_write_start(uv_write_t *req,
                                  uv_pipe_t *pipe,
                                  void *data,
                                  const void *buffer) {
  if (req == NULL || pipe == NULL || data == NULL || buffer == NULL)
    return UV_EINVAL;
  uv_req_set_data((uv_req_t *)req, data);
  return uv_write(req, (uv_stream_t *)pipe, (const uv_buf_t *)buffer, 1,
                  titan_uvshim_write_cb);
}

int titan_uvshim_pipe_is_closing(const uv_pipe_t *pipe) {
  return uv_is_closing((const uv_handle_t *)pipe);
}

void titan_uvshim_pipe_close(uv_pipe_t *pipe) {
  uv_close((uv_handle_t *)pipe, titan_uvshim_close_cb);
}

int titan_uvshim_process_spawn(uv_loop_t *loop,
                               uv_process_t *process,
                               void *data,
                               const char *file,
                               titan_uvshim_char_ptr *argv,
                               int64_t argv_count,
                               const int *endpoints,
                               int endpoint_count,
                               int *initialized) {
  uv_process_options_t options;
  uv_stdio_container_t stdio[3];
  int64_t index;
  int status;

  if (initialized == NULL)
    return UV_EINVAL;
  *initialized = 0;
  if (loop == NULL || process == NULL || data == NULL || file == NULL ||
      argv == NULL || argv_count < 1 || argv_count > INT_MAX ||
      endpoints == NULL || endpoint_count != TITAN_UV_STDIO_ENDPOINT_COUNT)
    return UV_EINVAL;
  for (index = 0; index < argv_count; index++)
    if (argv[index] == NULL)
      return UV_EINVAL;
  if (argv[argv_count] != NULL ||
      endpoints[TITAN_UV_STDIO_STDIN_CHILD] <= TITAN_UV_LAST_STDIO_FD ||
      endpoints[TITAN_UV_STDIO_STDOUT_CHILD] <= TITAN_UV_LAST_STDIO_FD ||
      endpoints[TITAN_UV_STDIO_STDERR_CHILD] <= TITAN_UV_LAST_STDIO_FD)
    return UV_EINVAL;

  memset(&options, 0, sizeof(options));
  memset(stdio, 0, sizeof(stdio));
  stdio[0].flags = UV_INHERIT_FD;
  stdio[0].data.fd = endpoints[TITAN_UV_STDIO_STDIN_CHILD];
  stdio[1].flags = UV_INHERIT_FD;
  stdio[1].data.fd = endpoints[TITAN_UV_STDIO_STDOUT_CHILD];
  stdio[2].flags = UV_INHERIT_FD;
  stdio[2].data.fd = endpoints[TITAN_UV_STDIO_STDERR_CHILD];
  options.exit_cb = titan_uvshim_process_exit_cb;
  options.file = file;
  options.args = argv;
  options.env = NULL;
  options.cwd = NULL;
  options.stdio_count = 3;
  options.stdio = stdio;

  /*
   * Exactly three valid UV_INHERIT_FD entries use libuv's stack stdio array;
   * init_stdio cannot reject them and open_stream is a no-op.  On supported
   * Linux/desktop-macOS every uv_spawn return therefore follows process.c's
   * ordinary return path, where the initialized process handle is closeable.
   * Inherit entries remain caller-owned on both success and failure.
   */
  status = uv_spawn(loop, process, &options);
  uv_handle_set_data((uv_handle_t *)process, data);
  *initialized = 1;
  return status;
}

int titan_uvshim_process_kill(uv_process_t *process, int signum) {
  if (process == NULL || signum <= 0)
    return UV_EINVAL;
  return uv_process_kill(process, signum);
}

int64_t titan_uvshim_process_get_pid(const uv_process_t *process) {
  if (process == NULL)
    return UV_EINVAL;
  return (int64_t)uv_process_get_pid(process);
}

int titan_uvshim_process_is_closing(const uv_process_t *process) {
  return uv_is_closing((const uv_handle_t *)process);
}

void titan_uvshim_process_close(uv_process_t *process) {
  uv_close((uv_handle_t *)process, titan_uvshim_close_cb);
}

int titan_uvshim_status_is_esrch(int status) {
  return status == UV_ESRCH;
}

void titan_uvshim_timer_set_data(uv_timer_t *timer, void *data) {
  uv_handle_set_data((uv_handle_t *)timer, data);
}

void *titan_uvshim_timer_get_data(const uv_timer_t *timer) {
  return uv_handle_get_data((const uv_handle_t *)timer);
}

int titan_uvshim_timer_is_closing(const uv_timer_t *timer) {
  return uv_is_closing((const uv_handle_t *)timer);
}

void titan_uvshim_timer_close(uv_timer_t *timer) {
  uv_close((uv_handle_t *)timer, titan_uvshim_close_cb);
}

void titan_uvshim_timer_close_discard(uv_timer_t *timer) {
  uv_close((uv_handle_t *)timer, NULL);
}

void titan_uvshim_fs_set_data(uv_fs_t *req, void *data) {
  uv_req_set_data((uv_req_t *)req, data);
}

void *titan_uvshim_fs_get_data(const uv_fs_t *req) {
  return uv_req_get_data((const uv_req_t *)req);
}

int titan_uvshim_fs_cancel(uv_fs_t *req) {
  return uv_cancel((uv_req_t *)req);
}

int titan_uvshim_fs_scandir_next(uv_fs_t *req, void *opaque_entry) {
  int status = uv_fs_scandir_next(req, (uv_dirent_t *)opaque_entry);
  return status == UV_EOF ? 1 : status;
}

const char *titan_uvshim_dirent_name(const void *opaque_entry) {
  return ((const uv_dirent_t *)opaque_entry)->name;
}

int titan_uvshim_error_eio(void) {
  return UV_EIO;
}

int titan_uvshim_error_eof(void) {
  return UV_EOF;
}

int titan_uvshim_error_ecanceled(void) {
  return UV_ECANCELED;
}

int titan_uvshim_error_eaddrnotavail(void) {
  return UV_EADDRNOTAVAIL;
}

int titan_uvshim_error_eoverflow(void) {
  return UV_EOVERFLOW;
}

int titan_uvshim_error_enosys(void) {
  return UV_ENOSYS;
}

int titan_uvshim_status_is_enobufs(int status) {
  return status == UV_ENOBUFS;
}

int titan_uvshim_status_is_enoent(int status) {
  return status == UV_ENOENT;
}

int64_t titan_uvshim_size_as_int64(size_t size) {
#if SIZE_MAX > INT64_MAX
  if (size > (size_t)INT64_MAX)
    return -1;
#endif
  return (int64_t)size;
}

int titan_uvshim_signal_number(const char *name) {
  if (name == NULL)
    return UV_EINVAL;
  if (strcmp(name, "hup") == 0)
    return SIGHUP;
  if (strcmp(name, "int") == 0)
    return SIGINT;
  if (strcmp(name, "quit") == 0)
    return SIGQUIT;
  if (strcmp(name, "kill") == 0)
    return SIGKILL;
  if (strcmp(name, "term") == 0)
    return SIGTERM;
  if (strcmp(name, "usr1") == 0)
    return SIGUSR1;
  if (strcmp(name, "usr2") == 0)
    return SIGUSR2;
  return UV_EINVAL;
}

const char *titan_uvshim_signal_name(int signum) {
  if (signum == SIGHUP)
    return "hup";
  if (signum == SIGINT)
    return "int";
  if (signum == SIGQUIT)
    return "quit";
  if (signum == SIGKILL)
    return "kill";
  if (signum == SIGTERM)
    return "term";
  if (signum == SIGUSR1)
    return "usr1";
  if (signum == SIGUSR2)
    return "usr2";
  return NULL;
}

int titan_uvshim_signal_is_waitable(int signum) {
  return signum != SIGKILL && titan_uvshim_signal_name(signum) != NULL;
}

int titan_uvshim_signal_init(uv_loop_t *loop,
                             uv_signal_t *signal,
                             void *data) {
  int status;
  if (loop == NULL || signal == NULL || data == NULL)
    return UV_EINVAL;
  status = uv_signal_init(loop, signal);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)signal, data);
  return status;
}

int titan_uvshim_signal_start_oneshot(uv_signal_t *signal, int signum) {
  if (signal == NULL || !titan_uvshim_signal_is_waitable(signum))
    return UV_EINVAL;
  return uv_signal_start_oneshot(signal, titan_uvshim_signal_cb, signum);
}

int titan_uvshim_signal_stop(uv_signal_t *signal) {
  if (signal == NULL)
    return UV_EINVAL;
  return uv_signal_stop(signal);
}

int titan_uvshim_signal_is_closing(const uv_signal_t *signal) {
  return uv_is_closing((const uv_handle_t *)signal);
}

void titan_uvshim_signal_close(uv_signal_t *signal) {
  uv_close((uv_handle_t *)signal, titan_uvshim_close_cb);
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

int titan_uvshim_buf_init(void *buf, char *base, int64_t len) {
  uv_buf_t *uvbuf = (uv_buf_t *)buf;

  if (len < 0 || (uint64_t)len > UINT_MAX) {
    return UV_EINVAL;
  }
  *uvbuf = uv_buf_init(base, (unsigned int)len);
  return 0;
}

int titan_uvshim_allocation_length_is_valid(int64_t length) {
  const size_t maximum_userdata = MAX_SIZE - udatamemoffset(0);
  return length >= 0 && (uint64_t)length <= maximum_userdata;
}

int titan_uvshim_buf_length_is_valid(int64_t length) {
  return titan_uvshim_allocation_length_is_valid(length) &&
         (uint64_t)length <= UINT_MAX;
}

int titan_uvshim_buf_init_slice(void *buf, char *base, int64_t total,
                                int64_t offset, int64_t length) {
  if (base == NULL || total < 0 || offset < 0 || length < 0 ||
      offset > total || length > total - offset ||
      (uint64_t)total > SIZE_MAX || (uint64_t)offset > PTRDIFF_MAX ||
      (uint64_t)length > UINT_MAX) {
    return UV_EINVAL;
  }
  return titan_uvshim_buf_init(buf, base + offset, length);
}

int titan_uvshim_bytes_copy(char *destination, int64_t capacity,
                            const char *source, int64_t length) {
  if (destination == NULL || source == NULL || capacity < 0 || length < 0 ||
      capacity < length || (uint64_t)capacity > SIZE_MAX ||
      (uint64_t)length > SIZE_MAX) {
    return UV_EINVAL;
  }
  memcpy(destination, source, (size_t)length);
  return 0;
}

int64_t titan_uvshim_bytes_find(const char *haystack,
                                int64_t haystack_length,
                                const char *needle,
                                int64_t needle_length) {
  int64_t offset;

  if (haystack_length < 0 || needle_length < 0 ||
      (haystack_length > 0 && haystack == NULL) ||
      (needle_length > 0 && needle == NULL) ||
      (uint64_t)haystack_length > SIZE_MAX ||
      (uint64_t)needle_length > SIZE_MAX ||
      (uint64_t)haystack_length > PTRDIFF_MAX ||
      (uint64_t)needle_length > PTRDIFF_MAX) {
    return UV_EINVAL;
  }
  if (needle_length == 0)
    return 0;
  if (needle_length > haystack_length)
    return -1;
  for (offset = 0; offset <= haystack_length - needle_length; offset++) {
    if (haystack[offset] == needle[0] &&
        memcmp(haystack + offset, needle, (size_t)needle_length) == 0) {
      return offset;
    }
  }
  return -1;
}

int titan_uvshim_bytes_slice_copy(char *destination, int64_t capacity,
                                  const char *source, int64_t total,
                                  int64_t offset, int64_t length) {
  if (capacity < 0 || total < 0 || offset < 0 || length < 0 ||
      (length > 0 && destination == NULL) ||
      (total > 0 && source == NULL) || offset > total ||
      length > total - offset || capacity < length ||
      (uint64_t)capacity > SIZE_MAX || (uint64_t)total > SIZE_MAX ||
      (uint64_t)offset > PTRDIFF_MAX || (uint64_t)length > SIZE_MAX) {
    return UV_EINVAL;
  }
  if (length > 0)
    memcpy(destination, source + offset, (size_t)length);
  return 0;
}

int titan_uvshim_text_copy(char *destination, int64_t capacity,
                           const char *source, int64_t length) {
  if (destination == NULL || source == NULL || length < 0 ||
      capacity <= 0 || length > INT64_MAX - 1 || capacity != length + 1) {
    return UV_EINVAL;
  }
  if ((uint64_t)capacity > SIZE_MAX || (uint64_t)length > PTRDIFF_MAX) {
    return UV_EINVAL;
  }
  if (memchr(source, '\0', (size_t)length) != NULL) {
    return UV_EINVAL;
  }
  memcpy(destination, source, (size_t)length);
  destination[length] = '\0';
  return 0;
}

int titan_uvshim_stat_extract(const void *opaque_statbuf, int64_t *size,
                              int64_t *mode, int64_t *modified_seconds,
                              int64_t *modified_nanoseconds, int *kind) {
  const uv_stat_t *statbuf = (const uv_stat_t *)opaque_statbuf;

  if (statbuf == NULL || size == NULL || mode == NULL ||
      modified_seconds == NULL || modified_nanoseconds == NULL ||
      kind == NULL) {
    return UV_EINVAL;
  }
  if (statbuf->st_size > INT64_MAX || statbuf->st_mode > INT64_MAX) {
    return UV_EOVERFLOW;
  }

  *size = (int64_t)statbuf->st_size;
  *mode = (int64_t)statbuf->st_mode;
  *modified_seconds = statbuf->st_mtim.tv_sec;
  *modified_nanoseconds = statbuf->st_mtim.tv_nsec;
  if (S_ISREG((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_FILE;
  } else if (S_ISDIR((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_DIRECTORY;
  } else if (S_ISLNK((mode_t)statbuf->st_mode)) {
    *kind = TITAN_UV_STAT_SYMLINK;
  } else {
    *kind = TITAN_UV_STAT_OTHER;
  }
  return 0;
}

struct titan_uv_walk_summary {
  int count;
  uv_handle_type first_type;
};

static void titan_uvshim_walk_summary_cb(uv_handle_t *handle, void *arg) {
  struct titan_uv_walk_summary *summary =
      (struct titan_uv_walk_summary *)arg;
  if (summary->count == 0)
    summary->first_type = uv_handle_get_type(handle);
  summary->count++;
}

static struct titan_uv_walk_summary titan_uvshim_walk_summary(
    uv_loop_t *loop) {
  struct titan_uv_walk_summary summary = {0, UV_UNKNOWN_HANDLE};
  uv_walk(loop, titan_uvshim_walk_summary_cb, &summary);
  return summary;
}

int titan_uvshim_loop_handle_count(uv_loop_t *loop) {
  return titan_uvshim_walk_summary(loop).count;
}

const char *titan_uvshim_loop_first_handle_type(uv_loop_t *loop) {
  struct titan_uv_walk_summary summary = titan_uvshim_walk_summary(loop);
  const char *name = uv_handle_type_name(summary.first_type);
  return name != NULL ? name : "unknown";
}

int titan_uvshim_status_is_ebusy(int status) {
  return status == UV_EBUSY;
}
