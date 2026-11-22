#ifndef TITAN_STDLIB_TEST_NODELAY_NATIVE_H
#define TITAN_STDLIB_TEST_NODELAY_NATIVE_H

#if defined(_WIN32)
#include <winsock2.h>
#else
#include <errno.h>
#include <limits.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#endif

/* Query the kernel TCP_NODELAY option of a borrowed descriptor from public
 * uv.fileno(); never adopt or close it. Return 0 or 1, or a negative native
 * error. A Windows SOCKET is not narrowed to a Unix descriptor.
 */
static inline int titan_test_tcp_nodelay(long long descriptor) {
  int value = 0;
#if defined(_WIN32)
  int length = (int) sizeof(value);
  if (getsockopt((SOCKET) descriptor, IPPROTO_TCP, TCP_NODELAY,
                 (char *) &value, &length) != 0) {
    return -WSAGetLastError();
  }
#else
  socklen_t length = sizeof(value);
  if (descriptor < 0 || descriptor > INT_MAX) return -EINVAL;
  if (getsockopt((int) descriptor, IPPROTO_TCP, TCP_NODELAY,
                 &value, &length) < 0) {
    return -errno;
  }
#endif
  return value != 0;
}

#endif
