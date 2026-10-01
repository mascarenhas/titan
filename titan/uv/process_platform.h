#ifndef TITAN_PROCESS_PLATFORM_H
#define TITAN_PROCESS_PLATFORM_H

#include <errno.h>
#include <uv.h>

/* Titan cannot conditionally import platform headers. Keep OS descriptor
 * representation and metadata probes here; Titan still owns classification,
 * diagnostics, descriptor cleanup, and all asynchronous stream ownership. */
typedef struct titan_parent_stdio_probe {
  int status;
  const char *operation;
  int is_socket;
  int family;
  int is_unix;
  int is_stream;
  int name_errno;
  int type_errno;
} titan_parent_stdio_probe;

#ifdef _WIN32
#define TITAN_UV_WINDOWS 1
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
  if (capacity == 0) return uv_translate_sys_error(GetLastError());
  for (;;) {
    if ((size_t)capacity > SIZE_MAX / sizeof(WCHAR)) return UV_ENOMEM;
    wide = (WCHAR *)malloc((size_t)capacity * sizeof(WCHAR));
    if (wide == NULL) return UV_ENOMEM;
    length = GetSystemDirectoryW(wide, capacity);
    if (length == 0) {
      status = uv_translate_sys_error(GetLastError());
      free(wide);
      return status;
    }
    if (length < capacity) break;
    free(wide);
    if (length == UINT_MAX) return UV_ENAMETOOLONG;
    capacity = length + 1;
  }
  bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                               NULL, 0, NULL, NULL);
  if (bytes == 0) {
    status = uv_translate_sys_error(GetLastError());
    free(wide);
    return status;
  }
  if (*size < (size_t)bytes) {
    *size = (size_t)bytes;
    free(wide);
    return UV_ENOBUFS;
  }
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                         buffer, bytes, NULL, NULL) == 0) {
    status = uv_translate_sys_error(GetLastError());
    free(wide);
    return status;
  }
  free(wide);
  *size = (size_t)bytes - 1;
  return 0;
}

static inline int titan_duplicate_parent_descriptor(uv_file descriptor,
                                                    uv_file *duplicate,
                                                    int *cloexec_failed) {
  HANDLE source = uv_get_osfhandle(descriptor);
  HANDLE copy;
  *duplicate = -1;
  *cloexec_failed = 0;
  if (source == INVALID_HANDLE_VALUE)
    return UV_EBADF;
  if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                       &copy, 0, FALSE, DUPLICATE_SAME_ACCESS))
    return uv_translate_sys_error(GetLastError());
  *duplicate = uv_open_osfhandle(copy);
  if (*duplicate < 0) {
    int saved_errno = errno;
    CloseHandle(copy);
    /* uv_translate_sys_error expects a Win32 error on Windows, not errno.
     * uv_open_osfhandle delegates to the CRT, whose documented failures are
     * EMFILE and EINVAL. Keep those domains distinct. */
    if (saved_errno == EMFILE) return UV_EMFILE;
    if (saved_errno == EINVAL) return UV_EINVAL;
    return UV_UNKNOWN;
  }
  return 0;
}

static inline int titan_close_parent_duplicate(uv_file descriptor) {
  if (descriptor < 0) return 0;
  /* uv_fs_close intentionally preserves descriptors 0..2 on Windows. An
   * owned duplicate can occupy one of those slots when another std fd was
   * closed; release that owned CRT descriptor as well as its OS handle. */
  if (_close(descriptor) == 0) return 0;
  return errno == EBADF ? UV_EBADF : UV_UNKNOWN;
}

static inline void titan_probe_parent_stdio(uv_file descriptor,
                                            titan_parent_stdio_probe *probe) {
  HANDLE handle = uv_get_osfhandle(descriptor);
  DWORD kind, error;
  /* Windows has no POSIX socket-evidence fallback. Only status/operation are
   * valid in this branch: unknown native handles never become guessed pipes. */
  probe->operation = "GetFileType";
  if (handle == INVALID_HANDLE_VALUE) {
    probe->status = UV_EBADF;
    return;
  }
  SetLastError(ERROR_SUCCESS);
  kind = GetFileType(handle);
  error = GetLastError();
  probe->status = kind == FILE_TYPE_UNKNOWN && error != ERROR_SUCCESS
      ? uv_translate_sys_error(error) : UV_ENOTSUP;
}
#else
#define TITAN_UV_WINDOWS 0
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static inline int titan_process_system_directory(char *buffer, size_t *size) {
  (void)buffer;
  (void)size;
  return UV_ENOSYS;
}

static inline int titan_duplicate_parent_descriptor(uv_file descriptor,
                                                    uv_file *duplicate,
                                                    int *cloexec_failed) {
  int status;
  *cloexec_failed = 0;
  do {
    *duplicate = dup(descriptor);
  } while (*duplicate < 0 && errno == EINTR);
  if (*duplicate < 0)
    return uv_translate_sys_error(errno);
  do {
    status = fcntl(*duplicate, F_SETFD, FD_CLOEXEC);
  } while (status < 0 && errno == EINTR);
  if (status < 0) {
    *cloexec_failed = 1;
    return uv_translate_sys_error(errno);
  }
  return 0;
}

static inline int titan_close_parent_duplicate(uv_file descriptor) {
  uv_fs_t request;
  int status;
  if (descriptor < 0) return 0;
  status = uv_fs_close(NULL, &request, descriptor, NULL);
  uv_fs_req_cleanup(&request);
  return status;
}

static inline void titan_probe_parent_stdio(uv_file descriptor,
                                            titan_parent_stdio_probe *probe) {
  struct stat metadata;
  struct sockaddr_storage address;
  socklen_t address_size = sizeof(address);
  int socket_type;
  socklen_t type_size = sizeof(socket_type);
  int name_status, type_status;
  probe->operation = "fstat";
  if (fstat(descriptor, &metadata) != 0) {
    probe->status = uv_translate_sys_error(errno);
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
#endif

#endif
