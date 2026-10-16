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
  if (tracked) staged_descriptor = -1;
  result = (int)syscall(SYS_close, descriptor);
  if (tracked && result == 0) {
    static const char message[] = "PASS: staged descriptor retired\n";
    (void)syscall(SYS_write, STDERR_FILENO, message, sizeof(message) - 1);
  }
  return result;
}
