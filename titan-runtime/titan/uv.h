#ifndef TITAN_UV_H
#define TITAN_UV_H

#include <stdint.h>

/*
 * GC-owned normalized address storage. The C implementation statically
 * verifies that this parser-visible opaque cell is large and aligned enough
 * for sockaddr_storage on every supported target. Titan allocates arrays with
 * titan_uvshim_address.sizeof/alignof and never inspects their bytes.
 */
typedef union titan_uvshim_address {
  void *align_pointer;
  int64_t align_integer;
  unsigned char bytes[256];
} titan_uvshim_address;

/*
 * Minimal libuv forward declarations for Titan's FFI.  The standard uv module
 * imports <uv.h> separately and generated C includes it first; keeping this
 * header narrow avoids presenting a second copy of libuv's declarations as
 * part of the private shim namespace.  The typedefs exist only for the FFI's
 * independent parse of this header.
 */
#ifndef UV_H
typedef struct uv_connect_s uv_connect_t;
typedef struct uv_fs_s uv_fs_t;
typedef struct uv_getaddrinfo_s uv_getaddrinfo_t;
typedef struct uv_handle_s uv_handle_t;
typedef struct uv_loop_s uv_loop_t;
typedef struct uv_shutdown_s uv_shutdown_t;
typedef struct uv_tcp_s uv_tcp_t;
typedef struct uv_timer_s uv_timer_t;
typedef struct uv_write_s uv_write_t;
#endif

/*
 * Callback-owner records use these fields in this exact order.  Titan record
 * fields are numbered from one at the Lua API/source level and live at the
 * corresponding zero-based Udata.uv index in the native trampoline.
 *
 * The first five fields are the common callback prefix.  Slots 6 through 8
 * are family-specific but retain the documented root/metadata/buffer roles.
 */
enum titan_uvshim_owner_lua_slot {
  TITAN_UV_OWNER_NATIVE_LUA_SLOT = 1,
  TITAN_UV_OWNER_STORAGE_LUA_SLOT = 2,
  TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT = 3,
  TITAN_UV_OWNER_MODULE_LUA_SLOT = 4,
  TITAN_UV_OWNER_DISPATCHER_LUA_SLOT = 5,
  TITAN_UV_OWNER_ROOT_LUA_SLOT = 6,
  TITAN_UV_OWNER_METADATA_LUA_SLOT = 7,
  TITAN_UV_OWNER_BUFFER_LUA_SLOT = 8,
  TITAN_UV_OWNER_LUA_SLOT_COUNT = 8
};

enum titan_uvshim_owner_c_index {
  TITAN_UV_OWNER_NATIVE_C_INDEX = 0,
  TITAN_UV_OWNER_STORAGE_C_INDEX = 1,
  TITAN_UV_OWNER_MAIN_THREAD_C_INDEX = 2,
  TITAN_UV_OWNER_MODULE_C_INDEX = 3,
  TITAN_UV_OWNER_DISPATCHER_C_INDEX = 4,
  TITAN_UV_OWNER_ROOT_C_INDEX = 5,
  TITAN_UV_OWNER_METADATA_C_INDEX = 6,
  TITAN_UV_OWNER_BUFFER_C_INDEX = 7,
  TITAN_UV_OWNER_C_INDEX_COUNT = 8
};

enum titan_uvshim_event_kind {
  TITAN_UV_EVENT_TIMER = 1,
  TITAN_UV_EVENT_HANDLE_CLOSE = 2,
  TITAN_UV_EVENT_FS = 3,
  TITAN_UV_EVENT_GETADDRINFO = 4,
  TITAN_UV_EVENT_CONNECT = 5,
  TITAN_UV_EVENT_WRITE = 6,
  TITAN_UV_EVENT_SHUTDOWN = 7,
  TITAN_UV_EVENT_STREAM_READ = 8,
  TITAN_UV_EVENT_CONNECTION = 9
};

/* Concrete wrappers for libuv's public base-handle/base-request API. */
void titan_uvshim_timer_set_data(uv_timer_t *timer, void *data);
void *titan_uvshim_timer_get_data(const uv_timer_t *timer);
int titan_uvshim_timer_is_closing(const uv_timer_t *timer);
void titan_uvshim_timer_close(uv_timer_t *timer);
void titan_uvshim_timer_close_discard(uv_timer_t *timer);

void titan_uvshim_fs_set_data(uv_fs_t *req, void *data);
void *titan_uvshim_fs_get_data(const uv_fs_t *req);
int titan_uvshim_fs_cancel(uv_fs_t *req);
int titan_uvshim_fs_scandir_next(uv_fs_t *req, void *entry);
const char *titan_uvshim_dirent_name(const void *entry);
int titan_uvshim_error_eio(void);
int titan_uvshim_error_eof(void);
int titan_uvshim_error_ecanceled(void);
int titan_uvshim_error_eaddrnotavail(void);

/*
 * DNS is submitted through this wrapper so the private header does not need
 * to expose platform addrinfo constants to Titan. The wrapper still calls
 * only public libuv APIs. Libuv copies node before this function returns.
 */
int titan_uvshim_getaddrinfo_start(uv_loop_t *loop,
                                   uv_getaddrinfo_t *req,
                                   void *data,
                                   const char *node,
                                   int port);
int titan_uvshim_getaddrinfo_cancel(uv_getaddrinfo_t *req);
int64_t titan_uvshim_addrinfo_count(const void *result);
int titan_uvshim_addrinfo_copy(const void *result,
                               void *address_storage,
                               int64_t capacity);
void titan_uvshim_addrinfo_free(void *result);

/* Concrete TCP/stream/request wrappers around public libuv base APIs. */
int titan_uvshim_tcp_init(uv_loop_t *loop, uv_tcp_t *tcp, void *data);
int titan_uvshim_tcp_is_closing(const uv_tcp_t *tcp);
void titan_uvshim_tcp_close(uv_tcp_t *tcp);
/* Private fault-test hook; production close remains graceful uv_close. */
int titan_uvshim_tcp_close_reset(uv_tcp_t *tcp);
int titan_uvshim_tcp_bind(uv_tcp_t *tcp,
                          const void *address_storage,
                          int64_t count,
                          int64_t index);
/* Private test-variant diagnostic; the public net API exposes no endpoint. */
int titan_uvshim_tcp_bound_port(const uv_tcp_t *tcp);
int titan_uvshim_tcp_listen_backlog_is_valid(int64_t backlog);
int titan_uvshim_tcp_listen(uv_tcp_t *tcp, int64_t backlog);
int titan_uvshim_tcp_accept(uv_tcp_t *server, uv_tcp_t *client);
int titan_uvshim_tcp_read_start(uv_tcp_t *tcp);
int titan_uvshim_tcp_read_stop(uv_tcp_t *tcp);
int titan_uvshim_tcp_connect_start(uv_connect_t *req,
                                   uv_tcp_t *tcp,
                                   void *data,
                                   const void *address_storage,
                                   int64_t count,
                                   int64_t index);
int titan_uvshim_tcp_write_start(uv_write_t *req,
                                 uv_tcp_t *tcp,
                                 void *data,
                                 const void *buffer);
int titan_uvshim_tcp_shutdown_start(uv_shutdown_t *req,
                                    uv_tcp_t *tcp,
                                    void *data);

/* Fixed callback shapes passed directly to public libuv start functions. */
void titan_uvshim_timer_cb(uv_timer_t *timer);
void titan_uvshim_close_cb(uv_handle_t *handle);
void titan_uvshim_fs_cb(uv_fs_t *req);

/*
 * Initialize a public uv_buf_t through an opaque pointer.  The opaque
 * parameter keeps uv_buf_t out of this private header while the implementation
 * still delegates construction to uv_buf_init.  Lengths that the portable
 * uv_buf_init API cannot represent are rejected instead of truncated.
 */
int titan_uvshim_buf_init(void *buf, char *base, int64_t len);
int titan_uvshim_buf_init_slice(void *buf, char *base, int64_t total,
                                int64_t offset, int64_t length);
int titan_uvshim_bytes_copy(char *destination, int64_t capacity,
                            const char *source, int64_t length);
/* Zero-based binary search: -1 means absent; UV_EINVAL means bad arguments. */
int64_t titan_uvshim_bytes_find(const char *haystack, int64_t haystack_length,
                                const char *needle, int64_t needle_length);
/* Checked explicit-length binary slice copy; no NUL-termination semantics. */
int titan_uvshim_bytes_slice_copy(char *destination, int64_t capacity,
                                  const char *source, int64_t total,
                                  int64_t offset, int64_t length);
int titan_uvshim_allocation_length_is_valid(int64_t length);
int titan_uvshim_buf_length_is_valid(int64_t length);

/* Copy a retained text argument into caller-owned NUL-terminated storage. */
int titan_uvshim_text_copy(char *destination, int64_t capacity,
                           const char *source, int64_t length);

enum titan_uvshim_stat_kind {
  TITAN_UV_STAT_OTHER = 0,
  TITAN_UV_STAT_FILE = 1,
  TITAN_UV_STAT_DIRECTORY = 2,
  TITAN_UV_STAT_SYMLINK = 3
};

/* Extract the portable public portion of an opaque uv_stat_t. */
int titan_uvshim_stat_extract(const void *statbuf, int64_t *size,
                              int64_t *mode, int64_t *modified_seconds,
                              int64_t *modified_nanoseconds, int *kind);

/* Outer-driver diagnostics for an unexpected UV_EBUSY loop close. */
int titan_uvshim_loop_handle_count(uv_loop_t *loop);
const char *titan_uvshim_loop_first_handle_type(uv_loop_t *loop);
int titan_uvshim_status_is_ebusy(int status);

#endif
