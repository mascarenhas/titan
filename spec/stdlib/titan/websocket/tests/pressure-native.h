#ifndef TITAN_WEBSOCKET_TEST_PRESSURE_NATIVE_H
#define TITAN_WEBSOCKET_TEST_PRESSURE_NATIVE_H

#if defined(__APPLE__)
#include <errno.h>
#include <limits.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#endif

/* A borrowed descriptor from public uv.fileno(); never adopt or close it.
 * Darwin may grow even a fixed receive buffer by 16*MSS to avoid a zero
 * window. Clamp the connected recipient after SYN processing, which replaces
 * a pre-connect setting. Linux/Windows retain their ordinary fixture setup.
 * Return 1 when applied, 0 when unnecessary here, or a negative native errno.
 * Do not narrow an ignored Windows socket token to a Unix descriptor.
 */
static inline int titan_websocket_fixture_mss(long long descriptor,
                                             int *observed) {
  *observed = 0;
#if defined(__APPLE__)
  const int requested = 256;
  socklen_t length = sizeof(*observed);
  if (descriptor < 0 || descriptor > INT_MAX) return -EINVAL;
  const int fd = (int) descriptor;
  if (setsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, &requested,
                 sizeof(requested)) < 0) return -errno;
  if (getsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, observed, &length) < 0)
    return -errno;
  if (length != sizeof(*observed) || *observed != requested) return -EINVAL;
  return 1;
#else
  (void) descriptor;
  return 0;
#endif
}

#endif
