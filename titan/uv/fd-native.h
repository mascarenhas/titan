#ifndef TITAN_UV_FD_NATIVE_H
#define TITAN_UV_FD_NATIVE_H
#include <uv.h>
#include <lua.h>
#include <stdint.h>
#include <limits.h>
typedef struct titan_uv_fd_storage { uv_os_fd_t value; } titan_uv_fd_storage;
/* uv_os_fd_t is a HANDLE on Windows and an int elsewhere. Titan has no
 * conditional import, so the two representations convert here. */
static inline int titan_uv_fd_from_integer(lua_Integer value, titan_uv_fd_storage* out) {
#ifdef _WIN32
  out->value = (HANDLE) (uintptr_t) value;
#else
  if (value < INT_MIN || value > INT_MAX) return UV_EINVAL;
  out->value = (int) value;
#endif
  return 0;
}
static inline lua_Integer titan_uv_fd_integer(uv_os_fd_t value) {
#ifdef _WIN32
  return (lua_Integer) (uintptr_t) value;
#else
  return value;
#endif
}
#endif
