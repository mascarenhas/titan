#ifndef TITAN_OS_PLATFORM_H
#define TITAN_OS_PLATFORM_H

#include <errno.h>
#include <stddef.h>


/* Positive statuses are native errno/Win32 errors. Negative values identify
 * only the synthetic conditions below; Titan maps them to public uv errors. */
#define TITAN_OS_ENOBUFS (-1)
#define TITAN_OS_ENOMEM (-2)
#define TITAN_OS_EINVAL (-3)
#define TITAN_OS_ENAMETOOLONG (-4)
#define TITAN_OS_EBADF (-5)
#define TITAN_OS_EMFILE (-6)
#define TITAN_OS_UNKNOWN (-7)
#define TITAN_OS_ENOTSUP (-8)
#define TITAN_OS_ENOSYS (-9)

/* Titan cannot conditionally import platform headers. Keep OS descriptor
 * representation and metadata probes here; Titan still owns classification,
 * diagnostics, descriptor cleanup, and all asynchronous stream ownership. */
typedef struct titan_parent_stdio_probe {
  int status;
  const char *operation;
  int is_socket;
  int is_listening;
  int is_connected;
  int family;
  int is_unix;
  int is_stream;
  int name_errno;
  int type_errno;
} titan_parent_stdio_probe;

#ifdef _WIN32
#define TITAN_OS_WINDOWS 1
#include <winsock2.h>
#include <io.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <windows.h>

/* Match libuv's sized UTF-8 buffer convention. GetSystemDirectoryW reports
 * WCHAR counts, including NUL only when the supplied capacity is too small. */
static inline int titan_process_system_directory(char *buffer, size_t *size) {
  UINT capacity = GetSystemDirectoryW(NULL, 0);
  WCHAR *wide;
  UINT length;
  int bytes, status;
  if (capacity == 0) return (int)GetLastError();
  for (;;) {
    if ((size_t)capacity > SIZE_MAX / sizeof(WCHAR)) return TITAN_OS_ENOMEM;
    wide = (WCHAR *)malloc((size_t)capacity * sizeof(WCHAR));
    if (wide == NULL) return TITAN_OS_ENOMEM;
    length = GetSystemDirectoryW(wide, capacity);
    if (length == 0) {
      status = (int)GetLastError();
      free(wide);
      return status;
    }
    if (length < capacity) break;
    free(wide);
    if (length == UINT_MAX) return TITAN_OS_ENAMETOOLONG;
    capacity = length + 1;
  }
  bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                               NULL, 0, NULL, NULL);
  if (bytes == 0) {
    status = (int)GetLastError();
    free(wide);
    return status;
  }
  if (*size < (size_t)bytes) {
    *size = (size_t)bytes;
    free(wide);
    return TITAN_OS_ENOBUFS;
  }
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                         buffer, bytes, NULL, NULL) == 0) {
    status = (int)GetLastError();
    free(wide);
    return status;
  }
  free(wide);
  *size = (size_t)bytes - 1;
  return 0;
}

static inline int titan_duplicate_parent_descriptor(int descriptor,
                                                    int *duplicate,
                                                    int *cloexec_failed) {
  HANDLE source = (HANDLE)_get_osfhandle(descriptor);
  HANDLE copy;
  *duplicate = -1;
  *cloexec_failed = 0;
  if (source == INVALID_HANDLE_VALUE)
    return TITAN_OS_EBADF;
  if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                       &copy, 0, FALSE, DUPLICATE_SAME_ACCESS))
    return (int)GetLastError();
  *duplicate = _open_osfhandle((intptr_t)copy, 0);
  if (*duplicate < 0) {
    int saved_errno = errno;
    CloseHandle(copy);
    /* uv_translate_sys_error expects a Win32 error on Windows, not errno.
     * uv_open_osfhandle delegates to the CRT, whose documented failures are
     * EMFILE and EINVAL. Keep those domains distinct. */
    if (saved_errno == EMFILE) return TITAN_OS_EMFILE;
    if (saved_errno == EINVAL) return TITAN_OS_EINVAL;
    return TITAN_OS_UNKNOWN;
  }
  return 0;
}

static inline int titan_close_parent_duplicate(int descriptor) {
  if (descriptor < 0) return 0;
  /* uv_fs_close intentionally preserves descriptors 0..2 on Windows. An
   * owned duplicate can occupy one of those slots when another std fd was
   * closed; release that owned CRT descriptor as well as its OS handle. */
  if (_close(descriptor) == 0) return 0;
  return errno == EBADF ? TITAN_OS_EBADF : TITAN_OS_UNKNOWN;
}

static inline void titan_inspect_parent_socket_windows(
    HANDLE handle, titan_parent_stdio_probe *probe) {
  int socket_type = 0;
  int type_size = (int)sizeof(socket_type);
  int error;
  /* The Runtime's libuv loop has already started Winsock via uv_loop_init. */
  if (getsockopt((SOCKET)(uintptr_t)handle, SOL_SOCKET, SO_TYPE,
                 (char *)&socket_type, &type_size) == 0) {
    probe->is_socket = 1;
    return;
  }
  error = WSAGetLastError();
  if (error != WSAENOTSOCK) {
    probe->operation = "getsockopt(SO_TYPE)";
    probe->status = error != 0 ? error : TITAN_OS_UNKNOWN;
  }
}

static inline void titan_probe_parent_stdio(int descriptor,
                                            titan_parent_stdio_probe *probe) {
  HANDLE handle = (HANDLE)_get_osfhandle(descriptor);
  DWORD kind, error;
  /* Windows has no POSIX socket-evidence fallback. GetFileType reports
   * FILE_TYPE_PIPE for sockets as well as pipes, so inspect Winsock metadata
   * before accepting a pipe guess or classifying an unknown handle. */
  probe->status = 0;
  probe->operation = "GetFileType";
  probe->is_socket = 0;
  if (handle == INVALID_HANDLE_VALUE) {
    probe->status = TITAN_OS_EBADF;
    return;
  }
  SetLastError(ERROR_SUCCESS);
  kind = GetFileType(handle);
  error = GetLastError();
  if (kind == FILE_TYPE_UNKNOWN && error != ERROR_SUCCESS) {
    probe->status = (int)error;
    return;
  }
  titan_inspect_parent_socket_windows(handle, probe);
  if (probe->status != 0 || probe->is_socket != 0)
    return;
  if (kind == FILE_TYPE_UNKNOWN)
    probe->status = TITAN_OS_ENOTSUP;
}

/* Present only because foreign imports are unconditional; Windows libuv never
 * classifies a parent descriptor as UV_TCP. */
static inline void titan_inspect_parent_tcp(int descriptor,
                                            titan_parent_stdio_probe *probe) {
  (void)descriptor;
  probe->status = TITAN_OS_ENOTSUP;
  probe->operation = "socket-backed parent stdio is not supported on Windows";
}
#else
#define TITAN_OS_WINDOWS 0
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
#include <fcntl.h>
#ifdef __APPLE__
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static inline int titan_process_system_directory(char *buffer, size_t *size) {
  (void)buffer;
  (void)size;
  return TITAN_OS_ENOSYS;
}

static inline int titan_duplicate_parent_descriptor(int descriptor,
                                                    int *duplicate,
                                                    int *cloexec_failed) {
  int status;
  *cloexec_failed = 0;
  do {
    *duplicate = dup(descriptor);
  } while (*duplicate < 0 && errno == EINTR);
  if (*duplicate < 0)
    return errno;
  do {
    status = fcntl(*duplicate, F_SETFD, FD_CLOEXEC);
  } while (status < 0 && errno == EINTR);
  if (status < 0) {
    *cloexec_failed = 1;
    return errno;
  }
  return 0;
}

static inline int titan_close_parent_duplicate(int descriptor) {
  if (descriptor < 0) return 0;
  /* close may have released the descriptor even on EINTR; never retry it. */
  if (close(descriptor) == 0) return 0;
  return errno;
}

static inline void titan_probe_parent_stdio(int descriptor,
                                            titan_parent_stdio_probe *probe) {
  struct stat metadata;
  struct sockaddr_storage address;
  socklen_t address_size = sizeof(address);
  int socket_type;
  socklen_t type_size = sizeof(socket_type);
  int name_status, type_status;
  probe->operation = "fstat";
  if (fstat(descriptor, &metadata) != 0) {
    probe->status = errno;
    return;
  }
  probe->status = 0;
  probe->is_socket = (metadata.st_mode & S_IFMT) == S_IFSOCK;
  if (!probe->is_socket)
    return;

  name_status = getsockname(descriptor, (struct sockaddr *)&address,
                           &address_size);
  probe->name_errno = name_status != 0 ? errno : 0;
  type_status = getsockopt(descriptor, SOL_SOCKET, SO_TYPE,
                          &socket_type, &type_size);
  probe->type_errno = type_status != 0 ? errno : 0;
  /* Read result storage only when its exact native probe succeeded. */
  if (name_status == 0) {
    probe->family = address.ss_family;
    probe->is_unix = address.ss_family == AF_UNIX;
  }
  if (type_status == 0)
    probe->is_stream = type_size == sizeof(socket_type) &&
                       socket_type == SOCK_STREAM;
}

static inline void titan_inspect_parent_tcp(int descriptor,
                                            titan_parent_stdio_probe *probe) {
  struct sockaddr_storage peer;
  socklen_t peer_size = sizeof(peer);
#ifdef __APPLE__
  struct tcp_connection_info info;
  socklen_t info_size = sizeof(info);
#else
  int listening = 0;
  socklen_t listening_size = sizeof(listening);
#endif
  probe->status = 0;
  probe->operation = NULL;
  probe->is_listening = 0;
  probe->is_connected = 0;
#ifdef __APPLE__
  if (getsockopt(descriptor, IPPROTO_TCP, TCP_CONNECTION_INFO,
                 &info, &info_size) == 0) {
    if (info_size >= sizeof(info.tcpi_state) &&
        info.tcpi_state == TCPS_LISTEN) {
      probe->is_listening = 1;
      return;
    }
  } else if (errno != ENOPROTOOPT && errno != EINVAL) {
    probe->status = errno;
    probe->operation = "getsockopt(TCP_CONNECTION_INFO)";
    return;
  }
#else
  if (getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN,
                 &listening, &listening_size) == 0) {
    if (listening_size == sizeof(listening) && listening != 0) {
      probe->is_listening = 1;
      return;
    }
  } else if (errno != ENOPROTOOPT && errno != EINVAL) {
    probe->status = errno;
    probe->operation = "getsockopt(SO_ACCEPTCONN)";
    return;
  }
#endif
  if (getpeername(descriptor, (struct sockaddr *)&peer, &peer_size) != 0) {
    if (errno == ENOTCONN || errno == EINVAL)
      return;
    probe->status = errno;
    probe->operation = "getpeername";
    return;
  }
  probe->is_connected = 1;
}
#endif

#endif
