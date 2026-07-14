#include <assert.h>
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

static void titan_uvshim_close_cb(uv_handle_t *handle);

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

static void titan_uvshim_signal_cb(uv_signal_t *signal, int signum) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)signal);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_SIGNAL, signum, 0, NULL);
}

static void titan_uvshim_process_exit_cb(uv_process_t *process,
                                         int64_t exit_status,
                                         int term_signal) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)process);
  size_t signal_size;

  assert(term_signal >= 0);
  signal_size = (size_t)term_signal;
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
  assert(ttisfulluserdata(slot));
  storage = uvalue(slot);
  assert(storage->len <= UINT_MAX);
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

  assert(loop != NULL);
  assert(req != NULL);
  assert(data != NULL);
  assert(node != NULL);
  assert(port >= 0 && port <= 65535);
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
    if (titan_uvshim_addrinfo_is_usable(entry))
      count++;
    entry = entry->ai_next;
  }
  return count;
}

void titan_uvshim_addrinfo_copy(const void *result,
                                void *address_storage) {
  const struct addrinfo *entry = (const struct addrinfo *)result;
  titan_uvshim_address *addresses =
      (titan_uvshim_address *)address_storage;

  while (entry != NULL) {
    if (titan_uvshim_addrinfo_is_usable(entry)) {
      assert(addresses != NULL);
      memset(addresses, 0, sizeof(*addresses));
      memcpy(addresses->bytes, entry->ai_addr, entry->ai_addrlen);
      addresses++;
    }
    entry = entry->ai_next;
  }
}

void titan_uvshim_addrinfo_free(void *result) {
  uv_freeaddrinfo((struct addrinfo *)result);
}

static const struct sockaddr *titan_uvshim_address_at(
    const void *address_storage, int64_t index) {
  const titan_uvshim_address *addresses =
      (const titan_uvshim_address *)address_storage;
  assert(addresses != NULL);
  assert(index >= 0);
  return (const struct sockaddr *)addresses[index].bytes;
}

int titan_uvshim_tcp_init(uv_loop_t *loop, uv_tcp_t *tcp, void *data) {
  int status;
  assert(loop != NULL);
  assert(tcp != NULL);
  assert(data != NULL);
  status = uv_tcp_init(loop, tcp);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)tcp, data);
  return status;
}

void titan_uvshim_tcp_close(uv_tcp_t *tcp) {
  uv_close((uv_handle_t *)tcp, titan_uvshim_close_cb);
}

int titan_uvshim_tcp_bind(uv_tcp_t *tcp,
                          const void *address_storage,
                          int64_t index) {
  const struct sockaddr *address =
      titan_uvshim_address_at(address_storage, index);
  assert(tcp != NULL);
  assert(address != NULL);
  return uv_tcp_bind(tcp, address, 0);
}

int titan_uvshim_tcp_listen(uv_tcp_t *tcp, int64_t backlog) {
  assert(tcp != NULL);
  assert(backlog > 0 && backlog <= INT_MAX);
  return uv_listen((uv_stream_t *)tcp, (int)backlog,
                   titan_uvshim_connection_cb);
}

int titan_uvshim_tcp_accept(uv_tcp_t *server, uv_tcp_t *client) {
  assert(server != NULL);
  assert(client != NULL);
  return uv_accept((uv_stream_t *)server, (uv_stream_t *)client);
}

int titan_uvshim_tcp_read_start(uv_tcp_t *tcp) {
  assert(tcp != NULL);
  return uv_read_start((uv_stream_t *)tcp, titan_uvshim_alloc_cb,
                       titan_uvshim_read_cb);
}

int titan_uvshim_tcp_read_stop(uv_tcp_t *tcp) {
  assert(tcp != NULL);
  return uv_read_stop((uv_stream_t *)tcp);
}

int titan_uvshim_tcp_connect_start(uv_connect_t *req,
                                   uv_tcp_t *tcp,
                                   void *data,
                                   const void *address_storage,
                                   int64_t index) {
  const struct sockaddr *address =
      titan_uvshim_address_at(address_storage, index);
  assert(req != NULL);
  assert(tcp != NULL);
  assert(data != NULL);
  assert(address != NULL);
  uv_req_set_data((uv_req_t *)req, data);
  return uv_tcp_connect(req, tcp, address, titan_uvshim_connect_cb);
}

int titan_uvshim_tcp_write_start(uv_write_t *req,
                                 uv_tcp_t *tcp,
                                 void *data,
                                 const void *buffer) {
  assert(req != NULL);
  assert(tcp != NULL);
  assert(data != NULL);
  assert(buffer != NULL);
  uv_req_set_data((uv_req_t *)req, data);
  return uv_write(req, (uv_stream_t *)tcp, (const uv_buf_t *)buffer, 1,
                  titan_uvshim_write_cb);
}

int titan_uvshim_tcp_shutdown_start(uv_shutdown_t *req,
                                    uv_tcp_t *tcp,
                                    void *data) {
  assert(req != NULL);
  assert(tcp != NULL);
  assert(data != NULL);
  uv_req_set_data((uv_req_t *)req, data);
  return uv_shutdown(req, (uv_stream_t *)tcp, titan_uvshim_shutdown_cb);
}

int titan_uvshim_pipe_init(uv_loop_t *loop,
                           uv_pipe_t *pipe,
                           void *data) {
  int status;
  assert(loop != NULL);
  assert(pipe != NULL);
  assert(data != NULL);
  status = uv_pipe_init(loop, pipe, 0);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)pipe, data);
  return status;
}

int titan_uvshim_pipe_read_start(uv_pipe_t *pipe) {
  assert(pipe != NULL);
  return uv_read_start((uv_stream_t *)pipe, titan_uvshim_alloc_cb,
                       titan_uvshim_read_cb);
}

int titan_uvshim_pipe_read_stop(uv_pipe_t *pipe) {
  assert(pipe != NULL);
  return uv_read_stop((uv_stream_t *)pipe);
}

int titan_uvshim_pipe_write_start(uv_write_t *req,
                                  uv_pipe_t *pipe,
                                  void *data,
                                  const void *buffer) {
  assert(req != NULL);
  assert(pipe != NULL);
  assert(data != NULL);
  assert(buffer != NULL);
  uv_req_set_data((uv_req_t *)req, data);
  return uv_write(req, (uv_stream_t *)pipe, (const uv_buf_t *)buffer, 1,
                  titan_uvshim_write_cb);
}

void titan_uvshim_pipe_close(uv_pipe_t *pipe) {
  uv_close((uv_handle_t *)pipe, titan_uvshim_close_cb);
}

int titan_uvshim_process_spawn(uv_loop_t *loop,
                               uv_process_t *process,
                               void *data,
                               titan_uvshim_char_ptr *argv,
                               uv_pipe_t *stdin_pipe,
                               uv_pipe_t *stdout_pipe,
                               uv_pipe_t *stderr_pipe) {
  uv_process_options_t options;
  uv_stdio_container_t stdio[3];
  int status;

  assert(loop != NULL);
  assert(process != NULL);
  assert(data != NULL);
  assert(argv != NULL);
  assert(argv[0] != NULL);
  assert(stdin_pipe != NULL);
  assert(stdout_pipe != NULL);
  assert(stderr_pipe != NULL);

  memset(&options, 0, sizeof(options));
  memset(stdio, 0, sizeof(stdio));
  stdio[0].flags = UV_CREATE_PIPE | UV_READABLE_PIPE;
  stdio[0].data.stream = (uv_stream_t *)stdin_pipe;
  stdio[1].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[1].data.stream = (uv_stream_t *)stdout_pipe;
  stdio[2].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[2].data.stream = (uv_stream_t *)stderr_pipe;
  options.exit_cb = titan_uvshim_process_exit_cb;
  options.file = argv[0];
  options.args = argv;
  options.env = NULL;
  options.cwd = NULL;
  options.stdio_count = 3;
  options.stdio = stdio;

  status = uv_spawn(loop, process, &options);
  uv_handle_set_data((uv_handle_t *)process, data);
  return status;
}

void titan_uvshim_process_close(uv_process_t *process) {
  uv_close((uv_handle_t *)process, titan_uvshim_close_cb);
}

void titan_uvshim_timer_set_data(uv_timer_t *timer, void *data) {
  uv_handle_set_data((uv_handle_t *)timer, data);
}

int titan_uvshim_timer_is_closing(const uv_timer_t *timer) {
  return uv_is_closing((const uv_handle_t *)timer);
}

void titan_uvshim_timer_close(uv_timer_t *timer) {
  uv_close((uv_handle_t *)timer, titan_uvshim_close_cb);
}

void titan_uvshim_fs_set_data(uv_fs_t *req, void *data) {
  uv_req_set_data((uv_req_t *)req, data);
}

int titan_uvshim_fs_cancel(uv_fs_t *req) {
  return uv_cancel((uv_req_t *)req);
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

int titan_uvshim_error_einval(void) {
  return UV_EINVAL;
}

int titan_uvshim_error_enobufs(void) {
  return UV_ENOBUFS;
}

int titan_uvshim_error_enoent(void) {
  return UV_ENOENT;
}

int titan_uvshim_error_esrch(void) {
  return UV_ESRCH;
}

int titan_uvshim_signal_number(const char *name) {
  assert(name != NULL);
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
  return 0;
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

int titan_uvshim_signal_init(uv_loop_t *loop,
                             uv_signal_t *signal,
                             void *data) {
  int status;
  assert(loop != NULL);
  assert(signal != NULL);
  assert(data != NULL);
  status = uv_signal_init(loop, signal);
  if (status == 0)
    uv_handle_set_data((uv_handle_t *)signal, data);
  return status;
}

int titan_uvshim_signal_start_oneshot(uv_signal_t *signal, int signum) {
  assert(signal != NULL);
  assert(signum != SIGKILL);
  assert(titan_uvshim_signal_name(signum) != NULL);
  return uv_signal_start_oneshot(signal, titan_uvshim_signal_cb, signum);
}

void titan_uvshim_signal_close(uv_signal_t *signal) {
  uv_close((uv_handle_t *)signal, titan_uvshim_close_cb);
}

void titan_uvshim_timer_cb(uv_timer_t *timer) {
  Udata *owner = (Udata *)uv_handle_get_data((uv_handle_t *)timer);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_TIMER, 0, 0, NULL);
}

static void titan_uvshim_close_cb(uv_handle_t *handle) {
  Udata *owner = (Udata *)uv_handle_get_data(handle);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_HANDLE_CLOSE, 0, 0, NULL);
}

void titan_uvshim_fs_cb(uv_fs_t *req) {
  Udata *owner = (Udata *)uv_req_get_data((uv_req_t *)req);
  lua_Integer result = (lua_Integer)uv_fs_get_result(req);
  titan_uvshim_dispatch(owner, TITAN_UV_EVENT_FS, result, 0, NULL);
}

int64_t titan_uvshim_buf_max_length(void) {
  return UINT_MAX;
}

void titan_uvshim_buf_init_slice(void *buf, char *base, int64_t offset,
                                 int64_t length) {
  uv_buf_t *uvbuf = (uv_buf_t *)buf;
  char *slice;

  assert(buf != NULL);
  assert(offset >= 0);
  assert(length >= 0);
  assert((uint64_t)offset <= PTRDIFF_MAX);
  assert((uint64_t)length <= UINT_MAX);
  assert(base != NULL || (offset == 0 && length == 0));
  slice = base == NULL ? NULL : base + offset;
  *uvbuf = uv_buf_init(slice, (unsigned int)length);
}

void titan_uvshim_bytes_copy(char *destination, const char *source,
                             int64_t length) {
  assert(length >= 0);
  assert((uint64_t)length <= SIZE_MAX);
  assert(destination != NULL || length == 0);
  assert(source != NULL || length == 0);
  if (length > 0)
    memcpy(destination, source, (size_t)length);
}

int64_t titan_uvshim_bytes_find(const char *haystack,
                                int64_t haystack_length,
                                const char *needle,
                                int64_t needle_length) {
  int64_t offset;

  assert(haystack_length >= 0);
  assert(needle_length >= 0);
  assert(haystack != NULL || haystack_length == 0);
  assert(needle != NULL || needle_length == 0);
  assert((uint64_t)haystack_length <= SIZE_MAX);
  assert((uint64_t)needle_length <= SIZE_MAX);
  assert((uint64_t)haystack_length <= PTRDIFF_MAX);
  assert((uint64_t)needle_length <= PTRDIFF_MAX);
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

void titan_uvshim_bytes_slice_copy(char *destination, const char *source,
                                   int64_t offset, int64_t length) {
  assert(offset >= 0);
  assert(length >= 0);
  assert(destination != NULL || length == 0);
  assert(source != NULL || (offset == 0 && length == 0));
  assert((uint64_t)offset <= PTRDIFF_MAX);
  assert((uint64_t)length <= SIZE_MAX);
  if (length > 0)
    memcpy(destination, source + offset, (size_t)length);
}

void titan_uvshim_text_copy(char *destination, const char *source,
                            int64_t length) {
  assert(destination != NULL);
  assert(source != NULL || length == 0);
  assert(length >= 0);
  assert(length <= INT64_MAX - 1);
  assert((uint64_t)length <= PTRDIFF_MAX);
  if (length > 0)
    memcpy(destination, source, (size_t)length);
  destination[length] = '\0';
}

void titan_uvshim_stat_extract(const void *opaque_statbuf, int64_t *size,
                               int64_t *mode, int64_t *modified_seconds,
                               int64_t *modified_nanoseconds, int *kind) {
  const uv_stat_t *statbuf = (const uv_stat_t *)opaque_statbuf;

  assert(statbuf != NULL);
  assert(size != NULL);
  assert(mode != NULL);
  assert(modified_seconds != NULL);
  assert(modified_nanoseconds != NULL);
  assert(kind != NULL);
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
}
