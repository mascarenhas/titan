#ifndef TITAN_OS_ENVIRONMENT_H
#define TITAN_OS_ENVIRONMENT_H

#include <string.h>
#include "os_platform.h"

/* Titan cannot conditionally import platform headers. Keep only the native
 * name comparison here; Titan owns the environment snapshot and its merge. */
#ifdef _WIN32
#include <stdint.h>
#include <stdlib.h>
#include <windows.h>

static inline int titan_process_environment_name_equal(const char *left,
                                                       const char *right) {
  int left_count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      left, -1, NULL, 0);
  int right_count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       right, -1, NULL, 0);
  WCHAR *left_wide;
  WCHAR *right_wide;
  int order;
  if (left_count == 0 || right_count == 0)
    return TITAN_OS_EINVAL;
  if ((size_t)left_count > SIZE_MAX / sizeof(WCHAR) ||
      (size_t)right_count > SIZE_MAX / sizeof(WCHAR))
    return TITAN_OS_ENOMEM;
  left_wide = (WCHAR *)malloc((size_t)left_count * sizeof(WCHAR));
  right_wide = (WCHAR *)malloc((size_t)right_count * sizeof(WCHAR));
  if (left_wide == NULL || right_wide == NULL) {
    free(left_wide);
    free(right_wide);
    return TITAN_OS_ENOMEM;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, left, -1,
                        left_wide, left_count) != left_count ||
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, right, -1,
                        right_wide, right_count) != right_count) {
    free(left_wide);
    free(right_wide);
    return TITAN_OS_EINVAL;
  }
  order = CompareStringOrdinal(left_wide, left_count - 1,
                               right_wide, right_count - 1, TRUE);
  free(left_wide);
  free(right_wide);
  if (order == 0)
    return TITAN_OS_EINVAL;
  return order == CSTR_EQUAL;
}
#else
static inline int titan_process_environment_name_equal(const char *left,
                                                       const char *right) {
  return strcmp(left, right) == 0;
}
#endif

#endif
