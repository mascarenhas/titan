#include <errno.h>
#include "os_descriptor_limit.h"
#ifdef _WIN32
int titan_test_fd_limit_lower(void) { return ENOSYS; }
int titan_test_fd_limit_restore(void) { return ENOSYS; }
int titan_test_fd_limit_restored(void) { return 0; }
#else
#include <sys/resource.h>
static struct rlimit saved;
static int active;
int titan_test_fd_limit_lower(void) {
    struct rlimit limited;
    if (active) return EBUSY;
    if (getrlimit(RLIMIT_NOFILE, &saved) != 0) return errno;
    limited = saved;
    limited.rlim_cur = 0;
    if (setrlimit(RLIMIT_NOFILE, &limited) != 0) return errno;
    active = 1;
    return 0;
}
int titan_test_fd_limit_restore(void) {
    if (!active) return 0;
    if (setrlimit(RLIMIT_NOFILE, &saved) != 0) return errno;
    active = 0;
    return 0;
}
int titan_test_fd_limit_restored(void) {
    struct rlimit current;
    return !active && getrlimit(RLIMIT_NOFILE, &current) == 0 &&
           current.rlim_cur == saved.rlim_cur && current.rlim_max == saved.rlim_max;
}
#endif
