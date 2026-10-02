/* Native oracle for the platform-only name comparison used by os.with_env. */
#include "process_environment.h"
#include <stdio.h>
#include <string.h>

int main(void) {
  char long_upper[8192];
  char long_lower[8192];
  int index;
  if (titan_process_environment_name_equal("EXACT", "EXACT") != 1 ||
      titan_process_environment_name_equal("A", "B") != 0)
    return 1;
  memset(long_upper, 'A', sizeof(long_upper) - 1);
  memset(long_lower, 'a', sizeof(long_lower) - 1);
  long_upper[sizeof(long_upper) - 1] = '\0';
  long_lower[sizeof(long_lower) - 1] = '\0';
  for (index = 0; index < 100; index++) {
#ifdef _WIN32
    if (titan_process_environment_name_equal("Path", "PATH") != 1 ||
        titan_process_environment_name_equal("\xc3\x84", "\xc3\xa4") != 1 ||
        titan_process_environment_name_equal("\xce\xa9", "\xcf\x89") != 1 ||
        titan_process_environment_name_equal("\xc3\xa9", "e\xcc\x81") != 0 ||
        titan_process_environment_name_equal("\xc3\x28", "valid") != UV_EINVAL ||
        titan_process_environment_name_equal(long_upper, long_lower) != 1)
      return 2;
#else
    if (titan_process_environment_name_equal("Path", "PATH") != 0 ||
        titan_process_environment_name_equal("\xc3\x84", "\xc3\xa4") != 0 ||
        titan_process_environment_name_equal(long_upper, long_lower) != 0)
      return 3;
#endif
  }
  puts("process environment name comparison: PASS");
  return 0;
}
