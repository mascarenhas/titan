#ifndef TITAN_UV_TEST_STDIO_PROBE_H
#define TITAN_UV_TEST_STDIO_PROBE_H

enum titan_uv_test_stdio_mode {
  TITAN_UV_TEST_STDIO_PIPE_ALL = 1,
  TITAN_UV_TEST_STDIO_FILE_STDOUT = 2,
  TITAN_UV_TEST_STDIO_TTY_SLAVE = 3,
  TITAN_UV_TEST_STDIO_SOCKET_STDOUT = 4
};

/* Test-only parent-stdio fixtures linked into the compiled native Titan runner. */
int titan_uv_test_stdio_setup(int mode);
int titan_uv_test_stdio_finish(int expected_nonblocking_mask);
const char *titan_uv_test_stdio_failure(void);
const char *titan_uv_test_stdio_output(int descriptor);
int titan_uv_test_stdio_open_fd_count(void);

#endif
