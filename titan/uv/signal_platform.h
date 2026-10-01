#ifndef TITAN_UV_SIGNAL_PLATFORM_H
#define TITAN_UV_SIGNAL_PLATFORM_H

#include <errno.h>
#include <signal.h>
#include <uv.h>

/* Titan has no conditional foreign imports. Keep unavailable native signal
 * constants and the Unix-only sigaction layout behind this private boundary.
 * These constants describe names, not whether libuv can deliver a signal. */
#ifdef _WIN32
#define TITAN_UV_SIGUSR1 0
#define TITAN_UV_SIGUSR2 0

static inline int titan_uv_ignore_sigpipe_if_default(void) {
  return 0;
}
#else
#define TITAN_UV_SIGUSR1 SIGUSR1
#define TITAN_UV_SIGUSR2 SIGUSR2

static inline int titan_uv_ignore_sigpipe_if_default(void) {
  struct sigaction current;
  if (sigaction(SIGPIPE, NULL, &current) != 0)
    return uv_translate_sys_error(errno);
  if (current.sa_handler != SIG_DFL)
    return 0;

  current.sa_handler = SIG_IGN;
  if (sigaction(SIGPIPE, &current, NULL) != 0)
    return uv_translate_sys_error(errno);
  return 0;
}
#endif

#endif
