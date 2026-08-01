#ifndef TITAN_UV_TEST_STDIO_PROBE_H
#define TITAN_UV_TEST_STDIO_PROBE_H

enum titan_uv_test_stdio_mode {
  TITAN_UV_TEST_STDIO_PIPE_ALL = 1,
  TITAN_UV_TEST_STDIO_BLOCKED_STDIN = 2,
  TITAN_UV_TEST_STDIO_FILE_STDOUT = 3,
  TITAN_UV_TEST_STDIO_TTY_SLAVE = 4,
  TITAN_UV_TEST_STDIO_TTY_MASTER = 5,
  TITAN_UV_TEST_STDIO_OUTPUT_PIPES = 6,
  TITAN_UV_TEST_STDIO_SOCKET_STDOUT = 7
};

/* Test-only parent-stdio fixtures used by uv_process_stdio_spec.lua. */
int titan_uv_test_stdio_setup(int mode);
int titan_uv_test_stdio_finish(int expected_nonblocking_mask);
const char *titan_uv_test_stdio_failure(void);
const char *titan_uv_test_stdio_output(int descriptor);
int titan_uv_test_stdio_open_fd_count(void);

#endif
