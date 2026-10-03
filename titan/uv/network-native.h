#ifndef TITAN_ISSUE194_NETWORK_NATIVE_H
#define TITAN_ISSUE194_NETWORK_NATIVE_H
#include <uv.h>
/* Embedded private state lets the C-only spawn handoff update this one flag
 * through the compiler's nominal-field projection, without a Titan GC loop. */
typedef struct titan_uv_pipe_eligibility {
  int available;
} titan_uv_pipe_eligibility;
static inline int titan_uv_network_is_windows(void) {
#ifdef _WIN32
  return 1;
#else
  return 0;
#endif
}
/* Unix try_write2 omits the source-fd check performed by write2 and asserts
 * later for a descriptor-less borrowed handle. Windows rejects all transfers
 * with EAGAIN; preserve that native behavior without checking its descriptor. */
static inline int titan_uv_try_write2_source_status(const uv_stream_t *source) {
#ifdef _WIN32
  (void) source;
  return 0;
#else
  uv_os_fd_t descriptor;
  return uv_fileno((const uv_handle_t *) source, &descriptor);
#endif
}
/* Windows accept implementations downcast before validating client kinds.
 * Unix has an explicit TCP/pipe/UDP client switch, including IPC UDP receipt. */
static inline int titan_uv_accept_compatible(const uv_stream_t *server,
                                            const uv_handle_t *client) {
#ifdef _WIN32
  if (server->type == UV_TCP) return client->type == UV_TCP;
  if (server->type == UV_NAMED_PIPE) {
    const uv_pipe_t *pipe = (const uv_pipe_t *) server;
    return client->type == (pipe->ipc ? UV_TCP : UV_NAMED_PIPE);
  }
  return 0;
#else
  return (server->type == UV_TCP || server->type == UV_NAMED_PIPE) &&
         (client->type == UV_TCP || client->type == UV_NAMED_PIPE ||
          client->type == UV_UDP);
#endif
}
#endif
