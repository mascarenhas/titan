#ifndef TITAN_SQLITE3_BROWSER_H
#define TITAN_SQLITE3_BROWSER_H

#include <stdint.h>
#include "titan/ffi.h"

/* The browser storage runtime's connection retirement (titan-browser-vfs.mjs
 * forwards it to the titan:sqlite3 ledger). Titan cannot declare a Wasm
 * import itself; calling it also makes every image that links titan.sqlite3
 * link the SQLite transport. */
TITAN_WASM_IMPORT("titan_browser_sql_retire_sync")
void titan_browser_sql_retire_sync(int32_t state, int64_t conn_id);

#endif
