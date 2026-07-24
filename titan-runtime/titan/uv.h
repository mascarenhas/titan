#ifndef TITAN_UV_H
#define TITAN_UV_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

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

/* Parser-visible pointer cell used for Titan/GC-owned argv vectors. */
typedef char *titan_uvshim_char_ptr;

/*
 * Minimal libuv forward declarations for Titan's FFI.  The standard uv module
 * imports <uv.h> separately and generated C includes it first; keeping this
 * header narrow avoids presenting a second copy of libuv's declarations as
 * part of the private shim namespace.  The typedefs exist only for the FFI's
 * independent parse of this header.
 */
#ifndef UV_H
struct addrinfo;
typedef struct uv_buf_t uv_buf_t;
typedef struct uv_connect_s uv_connect_t;
typedef struct uv_fs_s uv_fs_t;
typedef struct uv_getaddrinfo_s uv_getaddrinfo_t;
typedef struct uv_handle_s uv_handle_t;
typedef struct uv_loop_s uv_loop_t;
typedef struct uv_process_s uv_process_t;
typedef struct uv_req_s uv_req_t;
typedef struct uv_signal_s uv_signal_t;
typedef struct uv_shutdown_s uv_shutdown_t;
typedef struct uv_stream_s uv_stream_t;
typedef struct uv_tcp_s uv_tcp_t;
typedef struct uv_timer_s uv_timer_t;
typedef struct uv_write_s uv_write_t;
#endif

/*
 * Callback-owner records use these fields in this exact order.  Titan record
 * fields are numbered from one at the Lua API/source level and live at the
 * corresponding zero-based Udata.uv index in the native trampoline.
 *
 * All callback owners use the same six fields. The final slot is
 * family-specific native I/O storage; families that need no such root use nil.
 */
enum titan_uvshim_owner_lua_slot {
  TITAN_UV_OWNER_NATIVE_LUA_SLOT = 1,
  TITAN_UV_OWNER_STORAGE_LUA_SLOT = 2,
  TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT = 3,
  TITAN_UV_OWNER_DISPATCHER_LUA_SLOT = 4,
  TITAN_UV_OWNER_METADATA_LUA_SLOT = 5,
  TITAN_UV_OWNER_BUFFER_LUA_SLOT = 6,
  TITAN_UV_OWNER_LUA_SLOT_COUNT = 6
};

enum titan_uvshim_owner_c_index {
  TITAN_UV_OWNER_NATIVE_C_INDEX = 0,
  TITAN_UV_OWNER_STORAGE_C_INDEX = 1,
  TITAN_UV_OWNER_MAIN_THREAD_C_INDEX = 2,
  TITAN_UV_OWNER_DISPATCHER_C_INDEX = 3,
  TITAN_UV_OWNER_METADATA_C_INDEX = 4,
  TITAN_UV_OWNER_BUFFER_C_INDEX = 5,
  TITAN_UV_OWNER_C_INDEX_COUNT = 6
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
  TITAN_UV_EVENT_CONNECTION = 9,
  TITAN_UV_EVENT_SIGNAL = 10,
  TITAN_UV_EVENT_PROCESS_EXIT = 11,
  TITAN_UV_EVENT_STREAM_ALLOC = 12
};

/*
 * Plain-C callback trampolines passed directly from Titan to public libuv
 * APIs. They are private to titan.uv's fixed six-slot owner protocol, not a
 * general callback API for user programs.
 */
void titan_uvshim_signal_cb(uv_signal_t *signal, int signum);
void titan_uvshim_process_exit_cb(uv_process_t *process,
                                  int64_t exit_status,
                                  int term_signal);
void titan_uvshim_getaddrinfo_cb(uv_getaddrinfo_t *req, int status,
                                 struct addrinfo *result);
void titan_uvshim_connect_cb(uv_connect_t *req, int status);
void titan_uvshim_write_cb(uv_write_t *req, int status);
void titan_uvshim_shutdown_cb(uv_shutdown_t *req, int status);
void titan_uvshim_alloc_cb(uv_handle_t *handle, size_t suggested_size,
                           uv_buf_t *buf);
void titan_uvshim_read_cb(uv_stream_t *stream, ssize_t nread,
                          const uv_buf_t *buf);
void titan_uvshim_connection_cb(uv_stream_t *server, int status);
void titan_uvshim_close_cb(uv_handle_t *handle);

/*
 * Libuv's Unix stream writes use write/writev, so a closed pipe can deliver
 * SIGPIPE before libuv reports UV_EPIPE. Ignore the signal only when the host
 * left its disposition at SIG_DFL; an embedding application's explicit
 * SIG_IGN or custom handler remains untouched.
 */
int titan_uvshim_ignore_sigpipe_if_default(void);

/* Fixed callback shapes passed directly to public libuv start functions. */
void titan_uvshim_timer_cb(uv_timer_t *timer);
void titan_uvshim_fs_cb(uv_fs_t *req);

#endif
