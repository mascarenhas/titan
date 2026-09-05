#ifndef TITAN_UV_TEST_STDIO_PROBE_H
#define TITAN_UV_TEST_STDIO_PROBE_H

enum titan_uv_test_stdio_mode {
  TITAN_UV_TEST_STDIO_PIPE_ALL = 1,
  TITAN_UV_TEST_STDIO_FILE_STDOUT = 2,
  TITAN_UV_TEST_STDIO_TTY_SLAVE = 3,
  TITAN_UV_TEST_STDIO_SOCKET_STDOUT = 4,
  TITAN_UV_TEST_STDIO_UNIX_STREAM_ALL = 5,
  TITAN_UV_TEST_STDIO_UNIX_DATAGRAM_STDOUT = 6,
  TITAN_UV_TEST_STDIO_INET_DATAGRAM_STDOUT = 7
};

enum titan_uv_test_stdio_metadata_probe {
  TITAN_UV_TEST_STDIO_DENY_NAME = 1,
  TITAN_UV_TEST_STDIO_DENY_TYPE = 2,
  TITAN_UV_TEST_STDIO_DENY_PEER = 4,
  TITAN_UV_TEST_STDIO_DENY_ALL = 7
};

/* Test-only parent-stdio fixtures linked into the compiled native Titan runner. */
int titan_uv_test_stdio_setup(int mode);
int titan_uv_test_stdio_finish(int expected_nonblocking_mask);
const char *titan_uv_test_stdio_failure(void);
const char *titan_uv_test_stdio_output(int descriptor);
int titan_uv_test_stdio_open_fd_count(void);
int titan_uv_test_stdio_metadata_denial_supported(void);
/* Install only in the fresh exec child, never in the aggregate test process. */
int titan_uv_test_stdio_deny_metadata(int probes, int descriptors,
                                      int access_error);
int titan_uv_test_stdio_close_child_stdout(void);

#endif
