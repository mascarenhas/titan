#ifndef TITAN_UV_TRANSFER_NATIVE_H
#define TITAN_UV_TRANSFER_NATIVE_H

#include <uv.h>
#include <errno.h>
#include <stdint.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

/* Handle duplication and close differ by platform, and the pending-request
 * fields are libuv internals that differ by platform too. Titan has no
 * conditional import, so each helper takes formals and returns a libuv status;
 * the transfer policy stays in titan/uv/transfer.titan. */
/* Implementation notes: doc/implementation/libuv-extension-guide.md#native-socket-and-pipe-handoff */
/* Native requests can remain pending after read_stop. In particular, Windows
 * zero-byte reads retain their source IOCP until terminal delivery. */
static inline int titan_uv_transfer_stream_status(const uv_stream_t *stream,
                                                 int allow_reading) {
  uv_os_fd_t descriptor;
  if (uv_is_closing((const uv_handle_t *)stream)) return UV_EBUSY;
  if (!allow_reading && uv_is_active((const uv_handle_t *)stream)) return UV_EBUSY;
  if (uv_stream_get_write_queue_size(stream) != 0) return UV_EBUSY;
#ifdef _WIN32
  if (stream->reqs_pending != 0) return UV_EBUSY;
#else
  if (stream->connect_req != NULL || stream->shutdown_req != NULL)
    return UV_EBUSY;
  /* Closing a bound Unix pipe unlinks its owned pathname. */
  if (stream->type == UV_NAMED_PIPE &&
      ((const uv_pipe_t *)stream)->pipe_fname != NULL) return UV_EBUSY;
#endif
  if (stream->type == UV_TCP &&
      (!uv_is_readable(stream) || !uv_is_writable(stream))) return UV_EINVAL;
  if (stream->type == UV_NAMED_PIPE) {
    const uv_pipe_t *pipe = (const uv_pipe_t *)stream;
    /* IPC framing and received native handles are owned by the old wrapper. */
    if (pipe->ipc) return UV_ENOTSUP;
    if (!uv_is_readable(stream) && !uv_is_writable(stream)) return UV_EINVAL;
  }
  return uv_fileno((const uv_handle_t *)stream, &descriptor);
}

#ifndef _WIN32
static inline int titan_uv_transfer_dup_fd(int descriptor, int *output) {
  int result;
  int status;
  do result = dup(descriptor); while (result < 0 && errno == EINTR);
  if (result < 0) return uv_translate_sys_error(errno);
  do status = fcntl(result, F_SETFD, FD_CLOEXEC);
  while (status < 0 && errno == EINTR);
  if (status < 0) {
    int saved = errno;
    close(result);
    return uv_translate_sys_error(saved);
  }
  *output = result;
  return 0;
}
#endif

static inline int titan_uv_transfer_dup_socket(const uv_tcp_t *source,
                                               uv_os_sock_t *output) {
  uv_os_fd_t descriptor;
  int status = uv_fileno((const uv_handle_t *)source, &descriptor);
  if (status < 0) return status;
#ifdef _WIN32
  WSAPROTOCOL_INFOW protocol;
  SOCKET duplicate;
  if (WSADuplicateSocketW((SOCKET)(uintptr_t)descriptor, GetCurrentProcessId(),
                          &protocol) != 0)
    return uv_translate_sys_error(WSAGetLastError());
  duplicate = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO,
                         FROM_PROTOCOL_INFO, &protocol, 0,
                         WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
  if (duplicate == INVALID_SOCKET)
    return uv_translate_sys_error(WSAGetLastError());
  *output = duplicate;
  return 0;
#else
  return titan_uv_transfer_dup_fd(descriptor, output);
#endif
}

/* uv_os_sock_t is an integer whose width depends on the platform. Titan's
 * checked casts do not reinterpret an integer as a pointer. */
static inline void *titan_uv_transfer_socket_pointer(uv_os_sock_t socket) {
  return (void *)(uintptr_t)socket;
}

static inline uv_os_sock_t titan_uv_transfer_socket_value(void *pointer) {
  return (uv_os_sock_t)(uintptr_t)pointer;
}

static inline int titan_uv_transfer_close_socket(uv_os_sock_t socket) {
#ifdef _WIN32
  if (closesocket(socket) == 0) return 0;
  return uv_translate_sys_error(WSAGetLastError());
#else
  if (close(socket) == 0) return 0;
  return uv_translate_sys_error(errno);
#endif
}

static inline int titan_uv_transfer_dup_pipe(const uv_pipe_t *source,
                                             uv_file *output) {
  uv_os_fd_t descriptor;
  int status = uv_fileno((const uv_handle_t *)source, &descriptor);
  if (status < 0) return status;
#ifdef _WIN32
  HANDLE duplicate;
  int result;
  if (!DuplicateHandle(GetCurrentProcess(), descriptor, GetCurrentProcess(),
                       &duplicate, 0, FALSE, DUPLICATE_SAME_ACCESS))
    return uv_translate_sys_error(GetLastError());
  result = _open_osfhandle((intptr_t)duplicate, _O_BINARY);
  if (result < 0) {
    int saved = errno;
    CloseHandle(duplicate);
    return saved == EMFILE ? UV_EMFILE : UV_EINVAL;
  }
  *output = result;
  return 0;
#else
  return titan_uv_transfer_dup_fd(descriptor, output);
#endif
}

static inline int titan_uv_transfer_close_file(uv_file file) {
#ifdef _WIN32
  if (_close(file) == 0) return 0;
  return errno == EBADF ? UV_EBADF : UV_EIO;
#else
  if (close(file) == 0) return 0;
  return uv_translate_sys_error(errno);
#endif
}

static inline int titan_uv_transfer_open_pipe(uv_pipe_t *pipe, uv_file file) {
  int status = uv_pipe_open(pipe, file);
#ifdef _WIN32
  /* libuv duplicates CRT descriptors 0..2 instead of adopting them. This
   * descriptor is our owned duplicate even when it occupied a vacant slot. */
  if (status == 0 && file >= 0 && file <= 2) _close(file);
#endif
  return status;
}

#endif
