#ifndef TITAN_FS_BROWSER_H
#define TITAN_FS_BROWSER_H

#include <stddef.h>
#include <stdint.h>
#include "titan/ffi.h"

/* The browser storage runtime's synchronous descriptor retirement
 * (titan-browser-vfs.mjs). Titan cannot declare a Wasm import itself;
 * calling it also makes every image that links titan.fs link the storage
 * runtime. */
TITAN_WASM_IMPORT("titan_browser_vfs_retire_sync")
int titan_browser_vfs_retire_sync(int32_t state, int32_t fd);

/* wasi-libc hides these without an X/Open or BSD feature macro; a feature
 * macro in a header would come too late in the generated translation unit. */
char *realpath(const char *, char *);
int getentropy(void *, size_t);

#endif
