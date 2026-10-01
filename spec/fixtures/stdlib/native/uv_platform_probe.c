/* Narrow native oracle for the platform-only descriptor representation.
 * Public process/stream behavior remains covered by Titan's native tests. */
#include "titan/uv/process_platform.h"
#include "titan/uv/signal_platform.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#endif

static void close_file(uv_file descriptor) {
  uv_fs_t request;
  assert(uv_fs_close(NULL, &request, descriptor, NULL) == 0);
  uv_fs_req_cleanup(&request);
}

static void check_pipe(uv_loop_t *loop, int make_low_descriptor) {
  uv_file pair[2], duplicate;
  uv_os_fd_t actual;
  uv_pipe_t stream;
  int cloexec_failed;
  assert(uv_pipe(pair, UV_NONBLOCK_PIPE, 0) == 0);
#ifdef _WIN32
  if (make_low_descriptor)
    _close(0);
#else
  (void)make_low_descriptor;
#endif
  assert(titan_duplicate_parent_descriptor(pair[0], &duplicate,
                                           &cloexec_failed) == 0);
  assert(duplicate >= 0 && duplicate != pair[0] && cloexec_failed == 0);
  assert(uv_get_osfhandle(duplicate) != uv_get_osfhandle(pair[0]));
#ifdef _WIN32
  {
    DWORD flags;
    assert(GetHandleInformation(uv_get_osfhandle(duplicate), &flags));
    assert((flags & HANDLE_FLAG_INHERIT) == 0);
    if (make_low_descriptor)
      assert(duplicate == 0);
  }
#else
  assert((fcntl(duplicate, F_GETFD) & FD_CLOEXEC) != 0);
#endif
  assert(uv_guess_handle(duplicate) == UV_NAMED_PIPE);
  assert(uv_pipe_init(loop, &stream, 0) == 0);
  assert(uv_pipe_open(&stream, duplicate) == 0);
  assert(uv_fileno((uv_handle_t *)&stream, &actual) == 0);
  if (actual != uv_get_osfhandle(duplicate))
    assert(titan_close_parent_duplicate(duplicate) == 0);
  uv_close((uv_handle_t *)&stream, NULL);
  assert(uv_run(loop, UV_RUN_DEFAULT) == 0);
#ifdef _WIN32
  assert(uv_get_osfhandle(duplicate) == INVALID_HANDLE_VALUE);
#endif
#ifdef _WIN32
  if (make_low_descriptor)
    assert(uv_get_osfhandle(0) == INVALID_HANDLE_VALUE);
#endif
  assert(uv_guess_handle(pair[0]) == UV_NAMED_PIPE);
  close_file(pair[0]);
  close_file(pair[1]);
}

int main(void) {
  uv_loop_t loop;
  titan_parent_stdio_probe probe;
  uv_file missing;
  int cloexec_failed;
  assert(titan_duplicate_parent_descriptor(-1, &missing,
                                           &cloexec_failed) == UV_EBADF);
  assert(missing == -1 && cloexec_failed == 0);
  titan_probe_parent_stdio(-1, &probe);
  assert(probe.status == UV_EBADF);
  assert(uv_loop_init(&loop) == 0);
  check_pipe(&loop, 0);
#ifdef _WIN32
  {
    DWORD before, after;
    assert(TITAN_UV_SIGUSR1 == 0 && TITAN_UV_SIGUSR2 == 0);
    assert(titan_uv_ignore_sigpipe_if_default() == 0);
    for (int i = 0; i < 8; i++) check_pipe(&loop, 0);
    assert(GetProcessHandleCount(GetCurrentProcess(), &before));
    for (int i = 0; i < 64; i++) {
      check_pipe(&loop, 0);
    }
    assert(GetProcessHandleCount(GetCurrentProcess(), &after));
    printf("owned-pipe handles after 64 cycles: %lu -> %lu\n",
           (unsigned long)before, (unsigned long)after);
    assert(after <= before);
    check_pipe(&loop, 1);
  }
#else
  {
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    titan_probe_parent_stdio(pair[0], &probe);
    assert(probe.status == 0 && probe.is_socket && probe.is_unix &&
           probe.is_stream && probe.name_errno == 0 && probe.type_errno == 0);
    close_file(pair[0]);
    close_file(pair[1]);
  }
#endif
  assert(uv_loop_close(&loop) == 0);
  puts("native platform descriptor ownership and metadata passed");
  return 0;
}
