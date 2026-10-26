#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Isolated Linux child fixture. Fail only the second dup in each explicitly
 * armed synchronous handoff, without changing process descriptor limits. */
static long generation;
static unsigned calls;
static int staged_descriptor = -1;
static int failed_close_descriptor = -1;
static int failed_close_attempts;

int titan_io_close_failure_attempts(void) { return failed_close_attempts; }
void titan_io_close_failure_release_guard(void) { failed_close_descriptor = -1; }

int __wrap_dup(int descriptor) {
  const char *value = getenv("TITAN_IO_DUP_FAILURE");
  int result;
  if (value != NULL && value[0] != '\0') {
    long requested = strtol(value, NULL, 10);
    if (requested != generation) {
      generation = requested;
      calls = 0;
      staged_descriptor = -1;
    }
    if (++calls == 2) { errno = EMFILE; return -1; }
  }
  result = (int)syscall(SYS_dup, descriptor);
  if (value != NULL && value[0] != '\0' && calls == 1)
    staged_descriptor = result;
  return result;
}

int __wrap_close(int descriptor) {
  int tracked = descriptor == staged_descriptor && generation == 4;
  int result;
  /* Return EINTR after a real close, then intercept any erroneous retry without
   * touching that descriptor number again: the OS may already have reused it. */
  if (descriptor == failed_close_descriptor) {
    failed_close_attempts++;
    errno = EINTR;
    return -1;
  }
  if (descriptor == staged_descriptor && generation >= 5 && generation <= 7) {
    staged_descriptor = -1;
    failed_close_descriptor = descriptor;
    failed_close_attempts++;
    result = (int)syscall(SYS_close, descriptor);
    if (result != 0) return result;
    errno = EINTR;
    return -1;
  }
  if (tracked) staged_descriptor = -1;
  result = (int)syscall(SYS_close, descriptor);
  if (tracked && result == 0) {
    static const char message[] = "PASS: staged descriptor retired\n";
    (void)syscall(SYS_write, STDERR_FILENO, message, sizeof(message) - 1);
  }
  return result;
}
