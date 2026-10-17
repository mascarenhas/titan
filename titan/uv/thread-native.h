#ifndef TITAN_UV_THREAD_NATIVE_H
#define TITAN_UV_THREAD_NATIVE_H
#include <uv.h>
/* One addressable native identifier. Both pthread_create and libuv's Windows
 * startup context own copies of the entry and argument; no worker borrows this
 * storage or enclosing Titan userdata. */
typedef struct titan_uv_thread_storage {
  uv_thread_t thread;
} titan_uv_thread_storage;
#endif
