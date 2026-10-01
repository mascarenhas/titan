#include "titan/uv/signal_platform.h"
#include <stdio.h>

#ifndef _WIN32
static void inherited_handler(int signum) {
  (void)signum;
}

static int verify_policy(void (*before)(int), void (*after)(int)) {
  struct sigaction setting;
  struct sigaction observed;
  setting.sa_handler = before;
  setting.sa_flags = SA_RESTART;
  if (sigemptyset(&setting.sa_mask) != 0 ||
      sigaddset(&setting.sa_mask, SIGUSR1) != 0 ||
      sigaction(SIGPIPE, &setting, NULL) != 0)
    return 1;
  if (titan_uv_ignore_sigpipe_if_default() != 0 ||
      sigaction(SIGPIPE, NULL, &observed) != 0)
    return 2;
  if (observed.sa_handler != after ||
      (observed.sa_flags & SA_RESTART) == 0 ||
      sigismember(&observed.sa_mask, SIGUSR1) != 1)
    return 3;
  return 0;
}
#endif

int main(void) {
#ifdef _WIN32
  if (TITAN_UV_SIGUSR1 != 0 || TITAN_UV_SIGUSR2 != 0 ||
      titan_uv_ignore_sigpipe_if_default() != 0)
    return 1;
  puts("Windows unavailable-name constants and SIGPIPE no-op passed");
#else
  struct sigaction original;
  int result;
  if (TITAN_UV_SIGUSR1 != SIGUSR1 || TITAN_UV_SIGUSR2 != SIGUSR2 ||
      sigaction(SIGPIPE, NULL, &original) != 0)
    return 1;
  result = verify_policy(SIG_DFL, SIG_IGN);
  if (result == 0)
    result = verify_policy(SIG_IGN, SIG_IGN);
  if (result == 0)
    result = verify_policy(inherited_handler, inherited_handler);
  if (sigaction(SIGPIPE, &original, NULL) != 0)
    return 2;
  if (result != 0)
    return 10 + result;
  puts("Unix default, ignored, and custom SIGPIPE policies passed");
#endif
  return 0;
}
