#ifndef TITAN_SPEC_LUA_SOURCE_FIXTURE_H
#define TITAN_SPEC_LUA_SOURCE_FIXTURE_H

#ifndef _WIN32
#include <sys/stat.h>
#endif

/* Windows has no filesystem FIFO whose ordinary open blocks for its peer.
 * Keep the declaration portable; the owning case reports that platform skip. */
static inline int titan_lua_test_mkfifo(const char *path) {
#ifdef _WIN32
  (void)path;
  return -1;
#else
  return mkfifo(path, 0600);
#endif
}

#endif
