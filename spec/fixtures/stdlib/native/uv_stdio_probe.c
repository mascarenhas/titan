#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uv_stdio_probe.h"

#define OUTPUT_CAPACITY 8192

static int active_mode;
static int target_mask;
static int saved_descriptors[3] = {-1, -1, -1};
static HANDLE peer_handles[3];
static char outputs[3][OUTPUT_CAPACITY];
static char failure_message[256];
static int allocated_console;
static HANDLE console_standard_handles[3];
static int child_saved_stdout = -1;
static SOCKET child_peer_socket = INVALID_SOCKET;
static const DWORD standard_kinds[3] = {
  STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
};

static void record_failure(const char *format, ...) {
  va_list arguments;
  if (failure_message[0] != '\0') return;
  va_start(arguments, format);
  vsnprintf(failure_message, sizeof(failure_message), format, arguments);
  va_end(arguments);
}

static HANDLE duplicate_handle(HANDLE source) {
  HANDLE copy = NULL;
  if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                       &copy, 0, FALSE, DUPLICATE_SAME_ACCESS))
    record_failure("could not duplicate stdio handle: Windows error %lu",
                   (unsigned long)GetLastError());
  return copy;
}

/* Transfer replacement into a binary CRT descriptor and the Win32 standard
 * handle table. Both forms are inherited by the ordinary child launch paths. */
static int replace_target(int target, HANDLE replacement, int access) {
  int descriptor = _open_osfhandle((intptr_t)replacement, access | _O_BINARY);
  int saved;
  HANDLE actual;
  if (descriptor < 0) {
    record_failure("could not open replacement fd %d: %s", target, strerror(errno));
    CloseHandle(replacement);
    return -1;
  }
  saved = _dup(target);
  if (saved < 0) {
    record_failure("could not save fd %d: %s", target, strerror(errno));
    _close(descriptor);
    return -1;
  }
  if (!SetHandleInformation((HANDLE)_get_osfhandle(saved), HANDLE_FLAG_INHERIT, 0) ||
      _dup2(descriptor, target) != 0) {
    record_failure("could not replace fd %d", target);
    _close(saved);
    _close(descriptor);
    return -1;
  }
  _close(descriptor);
  saved_descriptors[target] = saved;
  target_mask |= 1 << target;
  actual = (HANDLE)_get_osfhandle(target);
  if (!SetHandleInformation(actual, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) ||
      !SetStdHandle(standard_kinds[target], actual)) {
    record_failure("could not publish fd %d: Windows error %lu", target,
                   (unsigned long)GetLastError());
    return -1;
  }
  return 0;
}

static int setup_pipe(int target) {
  static const char input[] = "parent-pipe-input";
  HANDLE reader, writer;
  DWORD written;
  if (!CreatePipe(&reader, &writer, NULL, OUTPUT_CAPACITY)) {
    record_failure("pipe(fd %d) failed: Windows error %lu", target,
                   (unsigned long)GetLastError());
    return -1;
  }
  if (target == 0) {
    if (!WriteFile(writer, input, sizeof(input) - 1, &written, NULL) ||
        written != sizeof(input) - 1) {
      record_failure("could not seed stdin pipe: Windows error %lu",
                     (unsigned long)GetLastError());
      CloseHandle(reader);
      CloseHandle(writer);
      return -1;
    }
    CloseHandle(writer);
    return replace_target(target, reader, _O_RDONLY);
  }
  peer_handles[target] = reader;
  return replace_target(target, writer, _O_WRONLY);
}

static int setup_file_stdout(void) {
  wchar_t directory[MAX_PATH + 1], path[MAX_PATH + 1];
  HANDLE file;
  DWORD length = GetTempPathW(MAX_PATH + 1, directory);
  if (length == 0 || length > MAX_PATH ||
      !GetTempFileNameW(directory, L"tus", 0, path)) {
    record_failure("could not create stdio temporary file: Windows error %lu",
                   (unsigned long)GetLastError());
    return -1;
  }
  file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     NULL, OPEN_EXISTING, FILE_ATTRIBUTE_TEMPORARY |
                     FILE_FLAG_DELETE_ON_CLOSE, NULL);
  if (file == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    DeleteFileW(path);
    record_failure("could not open stdio temporary file: Windows error %lu",
                   (unsigned long)error);
    return -1;
  }
  peer_handles[1] = duplicate_handle(file);
  if (peer_handles[1] == NULL) { CloseHandle(file); return -1; }
  return replace_target(1, file, _O_RDWR);
}

static int setup_console(void) {
  HANDLE screen;
  COORD origin = {0, 0};
  int index;
  if (GetConsoleCP() == 0) {
    HANDLE previous[3];
    for (index = 0; index < 3; index++)
      previous[index] = GetStdHandle(standard_kinds[index]);
    if (!AllocConsole()) {
      record_failure("could not allocate private console: Windows error %lu",
                     (unsigned long)GetLastError());
      return -1;
    }
    allocated_console = 1;
    /* Only the newly allocated fixture console may be hidden or freed. An
     * inherited console is never activated, hidden, resized, or detached. */
    ShowWindow(GetConsoleWindow(), SW_HIDE);
    for (index = 0; index < 3; index++) {
      HANDLE created = GetStdHandle(standard_kinds[index]);
      int owned = created != NULL && created != INVALID_HANDLE_VALUE;
      int other;
      for (other = 0; other < 3; other++)
        if (created == previous[other]) owned = 0;
      console_standard_handles[index] = owned ? created : NULL;
      if (!SetStdHandle(standard_kinds[index], previous[index])) {
        record_failure("could not restore standard handle after AllocConsole");
        return -1;
      }
    }
  }
  screen = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
  if (screen == INVALID_HANDLE_VALUE) {
    record_failure("could not create console screen buffer: Windows error %lu",
                   (unsigned long)GetLastError());
    return -1;
  }
  if (!SetConsoleCursorPosition(screen, origin)) {
    record_failure("could not reset private console cursor");
    CloseHandle(screen);
    return -1;
  }
  peer_handles[1] = duplicate_handle(screen);
  if (peer_handles[1] == NULL) { CloseHandle(screen); return -1; }
  return replace_target(1, screen, _O_WRONLY);
}

static void restore_targets(void) {
  int target;
  for (target = 0; target < 3; target++) {
    if (!(target_mask & (1 << target))) continue;
    if (_dup2(saved_descriptors[target], target) != 0 ||
        !SetStdHandle(standard_kinds[target], (HANDLE)_get_osfhandle(target)))
      record_failure("could not restore fd %d", target);
    _close(saved_descriptors[target]);
    saved_descriptors[target] = -1;
  }
}

static void read_pipe(int target) {
  size_t offset = 0;
  for (;;) {
    DWORD available, received;
    if (!PeekNamedPipe(peer_handles[target], NULL, 0, NULL, &available, NULL)) {
      DWORD error = GetLastError();
      if (error != ERROR_BROKEN_PIPE)
        record_failure("could not inspect captured fd %d: Windows error %lu",
                       target, (unsigned long)error);
      break;
    }
    if (available == 0) {
      record_failure("fd %d still had a live writer after Runtime teardown", target);
      break;
    }
    if (available > OUTPUT_CAPACITY - 1 - offset) {
      record_failure("captured fd %d output exceeded test capacity", target);
      break;
    }
    if (!ReadFile(peer_handles[target], outputs[target] + offset,
                   available, &received, NULL) || received != available) {
      record_failure("could not read captured fd %d: Windows error %lu", target,
                     (unsigned long)GetLastError());
      break;
    }
    offset += received;
  }
  outputs[target][offset] = '\0';
}

static void read_file(void) {
  LARGE_INTEGER length, origin;
  DWORD received;
  origin.QuadPart = 0;
  if (!GetFileSizeEx(peer_handles[1], &length) ||
      length.QuadPart < 0 || length.QuadPart >= OUTPUT_CAPACITY ||
      !SetFilePointerEx(peer_handles[1], origin, NULL, FILE_BEGIN) ||
      !ReadFile(peer_handles[1], outputs[1], (DWORD)length.QuadPart,
                 &received, NULL) || received != (DWORD)length.QuadPart) {
    record_failure("could not read captured stdio file");
    return;
  }
  outputs[1][received] = '\0';
}

static void read_console(void) {
  CONSOLE_SCREEN_BUFFER_INFO info;
  wchar_t wide[OUTPUT_CAPACITY];
  COORD origin = {0, 0};
  DWORD length, received;
  int bytes;
  if (!GetConsoleScreenBufferInfo(peer_handles[1], &info)) {
    record_failure("could not inspect captured console");
    return;
  }
  length = (DWORD)info.dwCursorPosition.Y * (DWORD)info.dwSize.X +
           (DWORD)info.dwCursorPosition.X;
  if (length >= OUTPUT_CAPACITY ||
      !ReadConsoleOutputCharacterW(peer_handles[1], wide, length, origin, &received) ||
      received != length) {
    record_failure("could not read captured console");
    return;
  }
  if (length == 0) return;
  bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, (int)length,
                               outputs[1], OUTPUT_CAPACITY - 1, NULL, NULL);
  if (bytes == 0) record_failure("could not encode captured console output");
  else outputs[1][bytes] = '\0';
}

int titan_uv_test_stdio_mode_supported(int mode) {
  return mode == TITAN_UV_TEST_STDIO_PIPE_ALL ||
         mode == TITAN_UV_TEST_STDIO_FILE_STDOUT ||
         mode == TITAN_UV_TEST_STDIO_TTY_SLAVE;
}

int titan_uv_test_stdio_setup(int mode) {
  int index;
  if (active_mode != 0) { record_failure("stdio fixture is already active"); return -1; }
  failure_message[0] = '\0';
  target_mask = 0;
  for (index = 0; index < 3; index++) {
    saved_descriptors[index] = -1;
    peer_handles[index] = NULL;
    console_standard_handles[index] = NULL;
    outputs[index][0] = '\0';
  }
  fflush(NULL);
  active_mode = mode;
  switch (mode) {
  case TITAN_UV_TEST_STDIO_PIPE_ALL:
    if (setup_pipe(0) || setup_pipe(1) || setup_pipe(2)) goto fail;
    break;
  case TITAN_UV_TEST_STDIO_FILE_STDOUT:
    if (setup_file_stdout()) goto fail;
    break;
  case TITAN_UV_TEST_STDIO_TTY_SLAVE:
    if (setup_console()) goto fail;
    break;
  default:
    record_failure("stdio mode %d requires Unix socket descriptors", mode);
    goto fail;
  }
  return 0;
fail:
  titan_uv_test_stdio_finish(0);
  return -1;
}

int titan_uv_test_stdio_finish(int expected_nonblocking_mask) {
  int target;
  /* O_NONBLOCK describes Unix shared open-file flags. Windows libuv uses its
   * own overlapped/non-overlapped pipe machinery without that descriptor flag. */
  (void)expected_nonblocking_mask;
  if (active_mode == 0) { record_failure("stdio fixture is not active"); return -1; }
  fflush(NULL);
  for (target = 0; target < 3; target++) {
    DWORD flags;
    if ((target_mask & (1 << target)) &&
        !GetHandleInformation(GetStdHandle(standard_kinds[target]), &flags))
      record_failure("Runtime teardown closed parent handle %d", target);
  }
  if (active_mode == TITAN_UV_TEST_STDIO_TTY_SLAVE && peer_handles[1] != NULL)
    read_console();
  restore_targets();
  for (target = 1; target < 3; target++) {
    if (peer_handles[target] == NULL) continue;
    if (active_mode == TITAN_UV_TEST_STDIO_FILE_STDOUT) read_file();
    else if (active_mode != TITAN_UV_TEST_STDIO_TTY_SLAVE) read_pipe(target);
    CloseHandle(peer_handles[target]);
    peer_handles[target] = NULL;
  }
  if (allocated_console) {
    for (target = 0; target < 3; target++) {
      int previous, duplicate = 0;
      for (previous = 0; previous < target; previous++)
        if (console_standard_handles[previous] == console_standard_handles[target])
          duplicate = 1;
      if (console_standard_handles[target] != NULL && !duplicate)
        CloseHandle(console_standard_handles[target]);
    }
    if (!FreeConsole()) record_failure("could not release private fixture console");
    allocated_console = 0;
  }
  active_mode = 0;
  target_mask = 0;
  return failure_message[0] == '\0' ? 0 : -1;
}

const char *titan_uv_test_stdio_failure(void) { return failure_message; }

const char *titan_uv_test_stdio_output(int descriptor) {
  return descriptor >= 0 && descriptor < 3 ? outputs[descriptor] : "";
}

int titan_uv_test_stdio_open_fd_count(void) {
  DWORD count;
  /* Count kernel handles too, so a leaked DuplicateHandle is observable even
   * when no CRT descriptor was published for it. */
  return GetProcessHandleCount(GetCurrentProcess(), &count) ? (int)count : -1;
}

int titan_uv_test_stdio_metadata_denial_supported(void) { return 0; }

int titan_uv_test_stdio_deny_metadata(int probes, int descriptors, int access_error) {
  (void)probes;
  (void)descriptors;
  (void)access_error;
  record_failure("stdio metadata denial requires Linux x86_64 or aarch64");
  return -1;
}

int titan_uv_test_stdio_close_child_stdout(void) {
  if (active_mode != 0) {
    record_failure("stdout may only be closed in the fresh child");
    return -1;
  }
  return _close(1);
}

const char *titan_uv_test_stdio_closed_probe(void) { return "GetFileType"; }

int titan_uv_test_stdio_windows_child_sockets_supported(void) { return 1; }

int titan_uv_test_stdio_install_child_socket_stdout(int socket_mode) {
  WSADATA wsa_data;
  SOCKET target_socket = INVALID_SOCKET;
  SOCKET listener = INVALID_SOCKET;
  SOCKET peer = INVALID_SOCKET;
  struct sockaddr_in address;
  int address_len = (int)sizeof(address);
  int saved = -1;
  int fd = -1;
  DWORD flags = WSA_FLAG_OVERLAPPED;
  if (active_mode != 0 || child_saved_stdout >= 0) {
    record_failure("child socket stdout fixture is already active");
    return -1;
  }
  if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
    record_failure("WSAStartup failed in child socket fixture");
    return -1;
  }
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;

  switch (socket_mode) {
  case TITAN_UV_TEST_CHILD_SOCKET_TCP_NONOVERLAPPED:
    flags = 0;
    /* fallthrough */
  case TITAN_UV_TEST_CHILD_SOCKET_TCP_OVERLAPPED:
    listener = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                          flags | WSA_FLAG_NO_HANDLE_INHERIT);
    if (listener == INVALID_SOCKET ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 1) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &address_len) != 0) {
      record_failure("could not prepare Windows loopback TCP listener");
      goto fail;
    }
    peer = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                      flags | WSA_FLAG_NO_HANDLE_INHERIT);
    if (peer == INVALID_SOCKET ||
        connect(peer, (struct sockaddr *)&address, address_len) != 0) {
      record_failure("could not connect Windows loopback TCP peer");
      goto fail;
    }
    target_socket = accept(listener, NULL, NULL);
    if (target_socket == INVALID_SOCKET) {
      record_failure("could not accept Windows loopback TCP socket");
      goto fail;
    }
    closesocket(listener);
    listener = INVALID_SOCKET;
    (void)SetHandleInformation((HANDLE)peer, HANDLE_FLAG_INHERIT, 0);
    break;
  case TITAN_UV_TEST_CHILD_SOCKET_TCP_LISTENER:
    target_socket = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                               WSA_FLAG_OVERLAPPED);
    if (target_socket == INVALID_SOCKET ||
        bind(target_socket, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(target_socket, 1) != 0) {
      record_failure("could not create Windows listening TCP socket");
      goto fail;
    }
    break;
  case TITAN_UV_TEST_CHILD_SOCKET_TCP_UNCONNECTED:
    target_socket = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                               WSA_FLAG_OVERLAPPED);
    if (target_socket == INVALID_SOCKET) {
      record_failure("could not create Windows unconnected TCP socket");
      goto fail;
    }
    break;
  case TITAN_UV_TEST_CHILD_SOCKET_UDP_UNCONNECTED:
    target_socket = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NULL, 0,
                               WSA_FLAG_OVERLAPPED);
    if (target_socket == INVALID_SOCKET) {
      record_failure("could not create Windows unconnected UDP socket");
      goto fail;
    }
    break;
  case TITAN_UV_TEST_CHILD_SOCKET_UDP_CONNECTED:
    peer = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NULL, 0,
                      WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (peer == INVALID_SOCKET ||
        bind(peer, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        getsockname(peer, (struct sockaddr *)&address, &address_len) != 0) {
      record_failure("could not bind Windows UDP peer socket");
      goto fail;
    }
    target_socket = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NULL, 0,
                               WSA_FLAG_OVERLAPPED);
    if (target_socket == INVALID_SOCKET ||
        connect(target_socket, (struct sockaddr *)&address, address_len) != 0) {
      record_failure("could not connect Windows UDP socket");
      goto fail;
    }
    (void)SetHandleInformation((HANDLE)peer, HANDLE_FLAG_INHERIT, 0);
    break;
  default:
    record_failure("unknown Windows child socket mode %d", socket_mode);
    return -1;
  }

  saved = _dup(1);
  if (saved < 0 ||
      !SetHandleInformation((HANDLE)_get_osfhandle(saved), HANDLE_FLAG_INHERIT, 0)) {
    record_failure("could not save child stdout before socket install");
    goto fail;
  }
  if (_close(1) != 0) {
    record_failure("could not close child stdout for socket install");
    goto fail;
  }
  fd = _open_osfhandle((intptr_t)target_socket, _O_WRONLY | _O_BINARY);
  if (fd < 0) {
    (void)_dup2(saved, 1);
    _close(saved);
    saved = -1;
    record_failure("could not wrap Windows socket in CRT fd");
    goto fail;
  }
  target_socket = INVALID_SOCKET;
  if (fd != 1) {
    if (_dup2(fd, 1) != 0) {
      _close(fd);
      (void)_dup2(saved, 1);
      _close(saved);
      record_failure("could not move Windows socket CRT fd to stdout");
      if (peer != INVALID_SOCKET) closesocket(peer);
      return -1;
    }
    _close(fd);
  }
  if (!SetStdHandle(STD_OUTPUT_HANDLE, (HANDLE)_get_osfhandle(1))) {
    (void)_dup2(saved, 1);
    _close(saved);
    if (peer != INVALID_SOCKET) closesocket(peer);
    record_failure("could not set STD_OUTPUT_HANDLE to Windows socket");
    return -1;
  }
  child_saved_stdout = saved;
  child_peer_socket = peer;
  return 0;

fail:
  if (saved >= 0) _close(saved);
  if (listener != INVALID_SOCKET) closesocket(listener);
  if (peer != INVALID_SOCKET) closesocket(peer);
  if (target_socket != INVALID_SOCKET) closesocket(target_socket);
  return -1;
}

int titan_uv_test_stdio_restore_child_socket_stdout(void) {
  int status = 0;
  if (child_saved_stdout >= 0) {
    if (_dup2(child_saved_stdout, 1) != 0 ||
        !SetStdHandle(STD_OUTPUT_HANDLE, (HANDLE)_get_osfhandle(1))) {
      record_failure("could not restore child stdout after socket check");
      status = -1;
    }
    _close(child_saved_stdout);
    child_saved_stdout = -1;
  }
  if (child_peer_socket != INVALID_SOCKET) {
    closesocket(child_peer_socket);
    child_peer_socket = INVALID_SOCKET;
  }
  return status;
}

#else
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 600

#include "uv_stdio_probe.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#define TITAN_UV_TEST_STDIO_SECCOMP 1
#if defined(__x86_64__)
#define TITAN_UV_TEST_STDIO_AUDIT_ARCH AUDIT_ARCH_X86_64
#else
#define TITAN_UV_TEST_STDIO_AUDIT_ARCH AUDIT_ARCH_AARCH64
#endif
#endif

#define OUTPUT_CAPACITY 8192

static int active_mode;
static int target_mask;
static int saved_descriptors[3] = { -1, -1, -1 };
static int peer_descriptors[3] = { -1, -1, -1 };
static int initial_flags[3] = { -1, -1, -1 };
static char outputs[3][OUTPUT_CAPACITY];
static char failure_message[256];

static void record_failure(const char *format, ...) {
  va_list arguments;
  if (failure_message[0] != '\0')
    return;
  va_start(arguments, format);
  vsnprintf(failure_message, sizeof(failure_message), format, arguments);
  va_end(arguments);
}

static int duplicate_cloexec(int descriptor) {
  int result;
#ifdef F_DUPFD_CLOEXEC
  do
    result = fcntl(descriptor, F_DUPFD_CLOEXEC, 10);
  while (result == -1 && errno == EINTR);
  if (result >= 0 || errno != EINVAL)
    return result;
#endif
  do
    result = dup(descriptor);
  while (result == -1 && errno == EINTR);
  if (result >= 0)
    (void) fcntl(result, F_SETFD, FD_CLOEXEC);
  return result;
}

static int replace_target(int target, int replacement) {
  int saved;
  int result;
  saved = duplicate_cloexec(target);
  if (saved < 0) {
    record_failure("could not save fd %d: %s", target, strerror(errno));
    return -1;
  }
  do
    result = dup2(replacement, target);
  while (result == -1 && errno == EINTR);
  if (result < 0) {
    record_failure("could not replace fd %d: %s", target, strerror(errno));
    close(saved);
    return -1;
  }
  saved_descriptors[target] = saved;
  initial_flags[target] = fcntl(target, F_GETFL);
  if (initial_flags[target] < 0) {
    record_failure("could not inspect fd %d: %s", target, strerror(errno));
    return -1;
  }
  target_mask |= 1 << target;
  return 0;
}

static int setup_input_pipe(void) {
  static const char input[] = "parent-pipe-input";
  int descriptors[2];
  if (pipe(descriptors) != 0) {
    record_failure("pipe(stdin) failed: %s", strerror(errno));
    return -1;
  }
  if (replace_target(0, descriptors[0]) != 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    return -1;
  }
  close(descriptors[0]);
  if (write(descriptors[1], input, sizeof(input) - 1) !=
      (ssize_t) (sizeof(input) - 1)) {
    record_failure("could not seed stdin pipe: %s", strerror(errno));
    close(descriptors[1]);
    return -1;
  }
  close(descriptors[1]);
  return 0;
}

static int setup_output_pipe(int target) {
  int descriptors[2];
  if (pipe(descriptors) != 0) {
    record_failure("pipe(fd %d) failed: %s", target, strerror(errno));
    return -1;
  }
  if (replace_target(target, descriptors[1]) != 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    return -1;
  }
  close(descriptors[1]);
  peer_descriptors[target] = descriptors[0];
  return 0;
}

static int setup_file_stdout(void) {
  char path[] = "/tmp/titan-uv-stdio-XXXXXX";
  int descriptor = mkstemp(path);
  if (descriptor < 0) {
    record_failure("mkstemp failed: %s", strerror(errno));
    return -1;
  }
  (void) unlink(path);
  if (replace_target(1, descriptor) != 0) {
    close(descriptor);
    return -1;
  }
  peer_descriptors[1] = descriptor;
  return 0;
}

static int setup_socket_stdout(int family, int socket_type) {
  int descriptor = socket(family, socket_type, 0);
  if (descriptor < 0) {
    record_failure("socket stdout setup failed: %s", strerror(errno));
    return -1;
  }
  if (replace_target(1, descriptor) != 0) {
    close(descriptor);
    return -1;
  }
  close(descriptor);
  return 0;
}

static int setup_unix_stream(int target) {
  static const char input[] = "parent-pipe-input";
  int descriptors[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) != 0) {
    record_failure("socketpair(fd %d) failed: %s", target, strerror(errno));
    return -1;
  }
  if (replace_target(target, descriptors[0]) != 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    return -1;
  }
  close(descriptors[0]);
  peer_descriptors[target] = descriptors[1];
  if (target == 0 &&
      (write(descriptors[1], input, sizeof(input) - 1) !=
         (ssize_t) (sizeof(input) - 1) ||
       shutdown(descriptors[1], SHUT_WR) != 0)) {
    record_failure("could not seed stdin socket: %s", strerror(errno));
    return -1;
  }
  return 0;
}

static int setup_tcp_stream(int target) {
  static const char input[] = "parent-tcp-input";
  struct sockaddr_in address;
  socklen_t address_len = sizeof(address);
  int listener = -1;
  int client = -1;
  int accepted = -1;

  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0)
    goto error;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(listener, (struct sockaddr *) &address, sizeof(address)) != 0 ||
      listen(listener, 1) != 0 ||
      getsockname(listener, (struct sockaddr *) &address, &address_len) != 0)
    goto error;
  client = socket(AF_INET, SOCK_STREAM, 0);
  if (client < 0 ||
      connect(client, (struct sockaddr *) &address, address_len) != 0)
    goto error;
  accepted = accept(listener, NULL, NULL);
  if (accepted < 0)
    goto error;
  close(listener);
  listener = -1;
  if (fcntl(client, F_SETFD, FD_CLOEXEC) != 0)
    goto error;
  if (replace_target(target, accepted) != 0)
    goto error;
  close(accepted);
  accepted = -1;
  peer_descriptors[target] = client;
  if (target == 0 &&
      (write(client, input, sizeof(input) - 1) !=
         (ssize_t) (sizeof(input) - 1) ||
       shutdown(client, SHUT_WR) != 0)) {
    record_failure("could not seed TCP stdin socket: %s", strerror(errno));
    return -1;
  }
  return 0;

error:
  record_failure("TCP stdio setup(fd %d) failed: %s", target, strerror(errno));
  if (listener >= 0) close(listener);
  if (client >= 0) close(client);
  if (accepted >= 0) close(accepted);
  return -1;
}

static int setup_tcp_listener_stdout(void) {
  struct sockaddr_in address;
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) {
    record_failure("TCP listener stdout setup failed: %s", strerror(errno));
    return -1;
  }
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(listener, (struct sockaddr *) &address, sizeof(address)) != 0 ||
      listen(listener, 1) != 0 ||
      replace_target(1, listener) != 0) {
    record_failure("TCP listener stdout setup failed: %s", strerror(errno));
    close(listener);
    return -1;
  }
  close(listener);
  return 0;
}

static int setup_connected_udp_stdout(void) {
  struct sockaddr_in address;
  socklen_t address_len = sizeof(address);
  int peer = -1;
  int descriptor = -1;

  peer = socket(AF_INET, SOCK_DGRAM, 0);
  if (peer < 0)
    goto error;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(peer, (struct sockaddr *) &address, sizeof(address)) != 0 ||
      getsockname(peer, (struct sockaddr *) &address, &address_len) != 0 ||
      fcntl(peer, F_SETFD, FD_CLOEXEC) != 0)
    goto error;
  descriptor = socket(AF_INET, SOCK_DGRAM, 0);
  if (descriptor < 0 ||
      connect(descriptor, (struct sockaddr *) &address, address_len) != 0 ||
      replace_target(1, descriptor) != 0)
    goto error;
  close(descriptor);
  peer_descriptors[0] = peer;
  return 0;

error:
  record_failure("connected UDP stdout setup failed: %s", strerror(errno));
  if (peer >= 0) close(peer);
  if (descriptor >= 0) close(descriptor);
  return -1;
}

static int setup_tty(void) {
  struct termios attributes;
  char *slave_name;
  int master = -1;
  int slave = -1;

  master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0)
    goto error;
  slave_name = ptsname(master);
  if (slave_name == NULL)
    goto error;
  slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave < 0)
    goto error;
  if (tcgetattr(slave, &attributes) != 0)
    goto error;
  cfmakeraw(&attributes);
  if (tcsetattr(slave, TCSANOW, &attributes) != 0)
    goto error;

  if (replace_target(1, slave) != 0)
    goto error;
  close(slave);
  peer_descriptors[1] = master;
  return 0;

error:
  record_failure("TTY stdio setup failed: %s", strerror(errno));
  if (master >= 0) close(master);
  if (slave >= 0) close(slave);
  return -1;
}

static void restore_targets(void) {
  int target;
  for (target = 0; target < 3; target++) {
    int result;
    if (!(target_mask & (1 << target)))
      continue;
    if (fcntl(target, F_GETFD) < 0 && errno == EBADF)
      record_failure("Runtime teardown closed parent fd %d", target);
    do
      result = dup2(saved_descriptors[target], target);
    while (result == -1 && errno == EINTR);
    if (result < 0)
      record_failure("could not restore fd %d: %s", target, strerror(errno));
    close(saved_descriptors[target]);
    saved_descriptors[target] = -1;
  }
}

static void read_peer(int target, int descriptor, int regular_file,
                      int allow_live_writer) {
  size_t offset = 0;
  ssize_t count;
  int flags;
  if (regular_file && lseek(descriptor, 0, SEEK_SET) < 0) {
    record_failure("could not rewind captured file: %s", strerror(errno));
    return;
  }
  if (!regular_file) {
    flags = fcntl(descriptor, F_GETFL);
    if (flags >= 0)
      (void) fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
  }
  for (;;) {
    count = read(descriptor, outputs[target] + offset,
                 OUTPUT_CAPACITY - 1 - offset);
    if (count > 0) {
      offset += (size_t) count;
      if (offset == OUTPUT_CAPACITY - 1) {
        record_failure("captured fd %d output exceeded test capacity", target);
        break;
      }
      continue;
    }
    if (count == 0 || (count < 0 && errno == EIO))
      break;
    if (count < 0 && errno == EINTR)
      continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (allow_live_writer)
        break;
      record_failure("fd %d still had a live writer after Runtime teardown",
                     target);
      break;
    }
    record_failure("could not read captured fd %d output: %s",
                   target, strerror(errno));
    break;
  }
  outputs[target][offset] = '\0';
}

int titan_uv_test_stdio_setup(int mode) {
  int index;
  if (active_mode != 0) {
    record_failure("stdio fixture is already active");
    return -1;
  }
  failure_message[0] = '\0';
  target_mask = 0;
  for (index = 0; index < 3; index++) {
    saved_descriptors[index] = -1;
    peer_descriptors[index] = -1;
    initial_flags[index] = -1;
    outputs[index][0] = '\0';
  }
  active_mode = mode;
  switch (mode) {
  case TITAN_UV_TEST_STDIO_PIPE_ALL:
    if (setup_input_pipe() != 0 || setup_output_pipe(1) != 0 ||
        setup_output_pipe(2) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_FILE_STDOUT:
    if (setup_file_stdout() != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_TTY_SLAVE:
    if (setup_tty() != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_SOCKET_STDOUT:
    if (setup_socket_stdout(AF_INET, SOCK_STREAM) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_UNIX_STREAM_ALL:
    if (setup_unix_stream(0) != 0 || setup_unix_stream(1) != 0 ||
        setup_unix_stream(2) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_UNIX_DATAGRAM_STDOUT:
    if (setup_socket_stdout(AF_UNIX, SOCK_DGRAM) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_INET_DATAGRAM_STDOUT:
    if (setup_socket_stdout(AF_INET, SOCK_DGRAM) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_TCP_CONNECTED_ALL:
    if (setup_tcp_stream(0) != 0 || setup_tcp_stream(1) != 0 ||
        setup_tcp_stream(2) != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_TCP_LISTENER_STDOUT:
    if (setup_tcp_listener_stdout() != 0)
      goto fail;
    break;
  case TITAN_UV_TEST_STDIO_INET_CONNECTED_DATAGRAM_STDOUT:
    if (setup_connected_udp_stdout() != 0)
      goto fail;
    break;
  default:
    record_failure("unknown stdio fixture mode %d", mode);
    goto fail;
  }
  return 0;

fail:
  titan_uv_test_stdio_finish(0);
  return -1;
}

int titan_uv_test_stdio_mode_supported(int mode) {
  return mode >= TITAN_UV_TEST_STDIO_PIPE_ALL &&
         mode <= TITAN_UV_TEST_STDIO_INET_CONNECTED_DATAGRAM_STDOUT;
}

int titan_uv_test_stdio_finish(int expected_nonblocking_mask) {
  int target;
  int regular_file = active_mode == TITAN_UV_TEST_STDIO_FILE_STDOUT;
  if (active_mode == 0) {
    record_failure("stdio fixture is not active");
    return -1;
  }
  for (target = 0; target < 3; target++) {
    int flags;
    int expected;
    if (!(target_mask & (1 << target)))
      continue;
    flags = fcntl(target, F_GETFL);
    if (flags < 0) {
      record_failure("parent fd %d is not open before restore", target);
      continue;
    }
    expected = (expected_nonblocking_mask & (1 << target)) != 0;
    if (((flags & O_NONBLOCK) != 0) != expected)
      record_failure("parent fd %d nonblocking state was %d, expected %d",
                     target, (flags & O_NONBLOCK) != 0, expected);
  }

  /* Closing the final PTY endpoint can discard unread peer input on some
   * hosts. Read the TTY case while the host-owned fd 1 is still open;
   * EAGAIN then means the asynchronous write has been fully observed. */
  if (active_mode == TITAN_UV_TEST_STDIO_TTY_SLAVE &&
      peer_descriptors[1] >= 0) {
    read_peer(1, peer_descriptors[1], 0, 1);
    close(peer_descriptors[1]);
    peer_descriptors[1] = -1;
  }

  restore_targets();
  if (peer_descriptors[0] >= 0) {
    close(peer_descriptors[0]);
    peer_descriptors[0] = -1;
  }
  for (target = 1; target < 3; target++) {
    if (peer_descriptors[target] < 0)
      continue;
    read_peer(target, peer_descriptors[target],
              regular_file && target == 1, 0);
    close(peer_descriptors[target]);
    peer_descriptors[target] = -1;
  }
  active_mode = 0;
  target_mask = 0;
  return failure_message[0] == '\0' ? 0 : -1;
}

const char *titan_uv_test_stdio_failure(void) {
  return failure_message;
}

const char *titan_uv_test_stdio_output(int descriptor) {
  if (descriptor < 0 || descriptor >= 3)
    return "";
  return outputs[descriptor];
}

int titan_uv_test_stdio_open_fd_count(void) {
  struct rlimit limit;
  rlim_t maximum;
  int descriptor;
  int count = 0;
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0)
    return -1;
  maximum = limit.rlim_cur;
  if (maximum == RLIM_INFINITY || maximum > 65536)
    maximum = 65536;
  for (descriptor = 0; (rlim_t) descriptor < maximum; descriptor++) {
    errno = 0;
    if (fcntl(descriptor, F_GETFD) >= 0 || errno != EBADF)
      count++;
  }
  return count;
}

int titan_uv_test_stdio_metadata_denial_supported(void) {
#ifdef TITAN_UV_TEST_STDIO_SECCOMP
  return 1;
#else
  return 0;
#endif
}

int titan_uv_test_stdio_deny_metadata(int probes, int descriptors,
                                      int access_error) {
#ifdef TITAN_UV_TEST_STDIO_SECCOMP
  const int calls[] = { SYS_getsockname, SYS_getsockopt, SYS_getpeername };
  struct sock_filter filter[16];
  struct sock_fprog program;
  unsigned int branches[3];
  unsigned int branch_count = 0;
  unsigned int count = 0;
  unsigned int fd_start;
  unsigned int index;
  const unsigned int denied_errno = access_error ? EACCES : EPERM;

  /* The fixture is inactive after exec. Denial belongs only to that child,
   * and cannot affect the aggregate's later tests or descriptor restoration. */
  if (active_mode != 0 || probes <= 0 || (probes & ~7) != 0 ||
      descriptors <= 0 || (descriptors & ~7) != 0) {
    record_failure("invalid child-only stdio metadata denial request");
    return -1;
  }
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
  filter[count++] = (struct sock_filter) BPF_JUMP(
      BPF_JMP | BPF_JEQ | BPF_K, TITAN_UV_TEST_STDIO_AUDIT_ARCH, 1, 0);
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
  for (index = 0; index < 3; index++) {
    if (!(probes & (1 << index)))
      continue;
    branches[branch_count++] = count;
    filter[count++] = (struct sock_filter) BPF_JUMP(
        BPF_JMP | BPF_JEQ | BPF_K, calls[index], 0, 0);
  }
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  fd_start = count;
  for (index = 0; index < branch_count; index++)
    filter[branches[index]].jt = (unsigned char) (fd_start - branches[index] - 1);
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0]));
  for (index = 0; index < 3; index++) {
    if (!(descriptors & (1 << index)))
      continue;
    filter[count++] = (struct sock_filter) BPF_JUMP(
        BPF_JMP | BPF_JEQ | BPF_K, index, 0, 1);
    filter[count++] = (struct sock_filter) BPF_STMT(
        BPF_RET | BPF_K, SECCOMP_RET_ERRNO | denied_errno);
  }
  filter[count++] = (struct sock_filter) BPF_STMT(
      BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  program.len = (unsigned short) count;
  program.filter = filter;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L) != 0 ||
      prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) {
    record_failure("could not install child stdio metadata denial: %s",
                   strerror(errno));
    return -1;
  }
  return 0;
#else
  (void) probes;
  (void) descriptors;
  (void) access_error;
  record_failure("stdio metadata denial requires Linux x86_64 or aarch64");
  return -1;
#endif
}

int titan_uv_test_stdio_close_child_stdout(void) {
  if (active_mode != 0) {
    record_failure("stdout may only be closed in the fresh child");
    return -1;
  }
  return close(1);
}

const char *titan_uv_test_stdio_closed_probe(void) { return "fstat"; }

int titan_uv_test_stdio_windows_child_sockets_supported(void) { return 0; }

int titan_uv_test_stdio_install_child_socket_stdout(int socket_mode) {
  (void) socket_mode;
  record_failure("Windows child socket stdout fixture requires _WIN32");
  return -1;
}

int titan_uv_test_stdio_restore_child_socket_stdout(void) { return 0; }
#endif
