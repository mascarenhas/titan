#ifndef TITAN_ASYNC_SIGNAL_PLATFORM_H
#define TITAN_ASYNC_SIGNAL_PLATFORM_H

#include <errno.h>
#include <stddef.h>
#include <signal.h>

/* Titan has no conditional foreign imports, and Windows has no SIGPIPE or
 * sigaction. Keep that platform-only layout here. This OS-only helper returns
 * native errno; the async owner translates it through the public uv API. */
static inline int titan_async_ignore_sigpipe_if_default(void) {
#ifdef _WIN32
  return 0;
#else
  struct sigaction current;
  if (sigaction(SIGPIPE, NULL, &current) != 0)
    return errno;
  if (current.sa_handler != SIG_DFL)
    return 0;

  current.sa_handler = SIG_IGN;
  if (sigaction(SIGPIPE, &current, NULL) != 0)
    return errno;
  return 0;
#endif
}

#endif
