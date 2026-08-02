#ifndef TITAN_UV_H
#define TITAN_UV_H

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
 * Libuv's write APIs borrow but do not modify payload bytes, while the
 * historical uv_buf_t surface still spells base as char *. Keep the one
 * deliberate const cast in C so Titan owners can retain strings directly.
 */
void titan_uvshim_buf_init_const(struct uv_buf_t *buf, const char *base,
                                 size_t len);

/*
 * Every native callback owner keeps its primary callback as its second record
 * field. Titan record fields live at the corresponding zero-based Udata.uv
 * index in the native trampoline. The callback closure retains its suspended
 * Task and any borrowed arguments; the remaining owner fields are only the
 * operation-specific native storage or persistent multi-shot state that must
 * survive the callback. Stream read and listener callbacks use the next two
 * fields on their multi-shot owners. The Lua main thread is stored once as the
 * private uv_loop_t data pointer.
 */
enum titan_uvshim_callback_c_index {
  TITAN_UV_PRIMARY_CALLBACK_C_INDEX = 1,
  TITAN_UV_READ_CALLBACK_C_INDEX = 2,
  TITAN_UV_CONNECTION_CALLBACK_C_INDEX = 3
};

/*
 * Plain-C callback trampolines passed directly from Titan to public libuv
 * APIs. They are private to titan.uv's native-owner protocol, not a general
 * callback API for user programs.
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
void titan_uvshim_walk_cb(struct uv_handle_s *handle, void *arg);

/* Fixed callback shapes passed directly to public libuv start functions. */
void titan_uvshim_timer_cb(struct uv_timer_s *timer);
void titan_uvshim_fs_cb(struct uv_fs_s *req);

#endif
