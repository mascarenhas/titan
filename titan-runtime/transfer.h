#ifndef TITAN_TRANSFER_H
#define TITAN_TRANSFER_H

#include "lua.h"
#include "lobject.h"
#include "titan/ffi.h"

/* Immutable code addresses and compile-time metadata only. Titan's private
 * foreign helpers reserve callback stack space; generated code uses the
 * calling state's rooted module and immediate captures. */
#define TITAN_TRANSFER_MANIFEST_SYMBOL "__titan_transfer_manifest"

typedef struct TitanTransferEntry {
    void *native;
    lua_CFunction strict;
    unsigned capture_count;
    void (*project)(lua_State *, CClosure *);
    void (*restore)(lua_State *, Udata *, int);
} TitanTransferEntry;

typedef struct TitanTransferModule {
    const char *name;
    unsigned entry_count;
    const TitanTransferEntry *entries;
} TitanTransferModule;

#endif
