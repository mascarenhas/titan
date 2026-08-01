#ifndef TITAN_UV_H
#define TITAN_UV_H

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/*
 * GC-owned normalized address storage. This parser-visible opaque cell is
 * deliberately overprovisioned and carries pointer/integer alignment. Titan
 * allocates arrays with titan_uvshim_address.sizeof/alignof and never inspects
 * their bytes.
 */
typedef union titan_uvshim_address {
  void *align_pointer;
  int64_t align_integer;
  unsigned char bytes[256];
} titan_uvshim_address;

/* Parser-visible pointer cell used for Titan/GC-owned argv vectors. */
typedef char *titan_uvshim_char_ptr;

/*
 * The Titan FFI cannot refer conditionally to a host macro that may not exist.
 * Normalize both its availability and value so Titan can select the
 * F_DUPFD_CLOEXEC fast path without making the generated C non-portable.
 */
#ifdef F_DUPFD_CLOEXEC
enum {
  TITAN_UVSHIM_HAS_F_DUPFD_CLOEXEC = 1,
  TITAN_UVSHIM_F_DUPFD_CLOEXEC = F_DUPFD_CLOEXEC
};
#else
enum {
  TITAN_UVSHIM_HAS_F_DUPFD_CLOEXEC = 0,
  TITAN_UVSHIM_F_DUPFD_CLOEXEC = 0
};
#endif

/*
 * Minimal libuv forward declarations for Titan's FFI. The standard uv module
 * imports <uv.h> separately and generated C includes it first; keeping this
 * header narrow avoids presenting a second copy of libuv's declarations as
 * part of the private shim namespace.
 */
struct addrinfo;
struct uv_buf_t;
struct uv_connect_s;
struct uv_fs_s;
struct uv_getaddrinfo_s;
struct uv_handle_s;
struct uv_process_s;
struct uv_signal_s;
struct uv_shutdown_s;
struct uv_stream_s;
struct uv_timer_s;
struct uv_write_s;

/*
 * Callback-owner records use these fields in this exact order.  Titan record
 * fields are numbered from one at the Lua API/source level and live at the
 * corresponding zero-based Udata.uv index in the native trampoline.
 *
 * All callback owners use the same five fields. The final slot is
 * family-specific native I/O storage; families that need no such root use nil.
 */
enum titan_uvshim_owner_lua_slot {
  TITAN_UV_OWNER_NATIVE_LUA_SLOT = 1,
  TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT = 2,
  TITAN_UV_OWNER_DISPATCHER_LUA_SLOT = 3,
  TITAN_UV_OWNER_METADATA_LUA_SLOT = 4,
  TITAN_UV_OWNER_BUFFER_LUA_SLOT = 5,
  TITAN_UV_OWNER_LUA_SLOT_COUNT = 5
};

enum titan_uvshim_owner_c_index {
  TITAN_UV_OWNER_NATIVE_C_INDEX = 0,
  TITAN_UV_OWNER_MAIN_THREAD_C_INDEX = 1,
  TITAN_UV_OWNER_DISPATCHER_C_INDEX = 2,
  TITAN_UV_OWNER_METADATA_C_INDEX = 3,
  TITAN_UV_OWNER_BUFFER_C_INDEX = 4,
  TITAN_UV_OWNER_C_INDEX_COUNT = 5
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
 * APIs. They are private to titan.uv's fixed five-slot owner protocol, not a
 * general callback API for user programs.
 */
void titan_uvshim_signal_cb(struct uv_signal_s *signal, int signum);
void titan_uvshim_process_exit_cb(struct uv_process_s *process,
                                  int64_t exit_status,
                                  int term_signal);
void titan_uvshim_getaddrinfo_cb(struct uv_getaddrinfo_s *req, int status,
                                 struct addrinfo *result);
void titan_uvshim_connect_cb(struct uv_connect_s *req, int status);
void titan_uvshim_write_cb(struct uv_write_s *req, int status);
void titan_uvshim_shutdown_cb(struct uv_shutdown_s *req, int status);
void titan_uvshim_alloc_cb(struct uv_handle_s *handle, size_t suggested_size,
                           struct uv_buf_t *buf);
void titan_uvshim_read_cb(struct uv_stream_s *stream, ssize_t nread,
                          const struct uv_buf_t *buf);
void titan_uvshim_connection_cb(struct uv_stream_s *server, int status);
void titan_uvshim_close_cb(struct uv_handle_s *handle);

/* Fixed callback shapes passed directly to public libuv start functions. */
void titan_uvshim_timer_cb(struct uv_timer_s *timer);
void titan_uvshim_fs_cb(struct uv_fs_s *req);

#endif
