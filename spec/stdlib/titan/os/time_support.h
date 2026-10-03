#ifndef TITAN_SPEC_OS_TIME_SUPPORT_H
#define TITAN_SPEC_OS_TIME_SUPPORT_H

#include <stdlib.h>
#include <time.h>

/* The timezone refresh operation has different declarations on Windows and
 * POSIX. Keep that platform boundary in this test-only native fixture. */
static inline int titan_spec_refresh_timezone(const char *zone) {
#ifdef _WIN32
  /* libuv owns the Win32 environment; UCRT keeps a separate cached copy.
   * Refresh that copy before asking the calendar routines to reread TZ. */
  int result = _putenv_s("TZ", zone != NULL ? zone : "");
  if (result != 0)
    return result;
  _tzset();
#else
  time_t instant = 0;
  (void)zone;
  /* POSIX localtime acts as though tzset was called. This avoids requiring a
   * feature-test macro just to expose the explicit tzset declaration. */
  (void)localtime(&instant);
#endif
  return 0;
}

#endif
