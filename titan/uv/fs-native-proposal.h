#ifndef TITAN_ISSUE194_FS_NATIVE_PROPOSAL_H
#define TITAN_ISSUE194_FS_NATIVE_PROPOSAL_H
#include <uv.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
/* The Titan FFI does not import floating constant macros. These exact accessors
 * expose the libuv values without assigning alternate numeric conventions. */
static inline double titan_uv_fs_utime_now(void) { return UV_FS_UTIME_NOW; }
static inline double titan_uv_fs_utime_omit(void) { return UV_FS_UTIME_OMIT; }
#endif
