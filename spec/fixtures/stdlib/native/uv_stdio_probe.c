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
  default:
    record_failure("unknown stdio fixture mode %d", mode);
    goto fail;
  }
  return 0;

fail:
  titan_uv_test_stdio_finish(0);
  return -1;
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
