#ifndef TITAN_UV_ABANDON_PROCESS_PROBE_H
#define TITAN_UV_ABANDON_PROCESS_PROBE_H

/* Loop abandonment closes watchers, not children. This test-only boundary
 * waits for the exit-zero child without importing libuv into its consumer. */
#ifdef _WIN32
static inline int titan_uv_abandon_reap(int pid) {
  /* Windows has no zombies; libuv already closed its process handle. A PID
   * lookup here could instead wait on an unrelated process after PID reuse. */
  (void) pid;
  return 0;
}
#else
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
static inline int titan_uv_abandon_reap(int pid) {
  int status;
  pid_t result;
  do {
    result = waitpid((pid_t) pid, &status, 0);
  } while (result < 0 && errno == EINTR);
  /* libuv may have reaped it before its suppressed exit delivery. */
  return result == (pid_t) pid || (result < 0 && errno == ECHILD) ? 0 : -1;
}
#endif

#endif
