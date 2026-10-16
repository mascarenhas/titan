#ifndef TITAN_TRANSFER_H
#define TITAN_TRANSFER_H

#include "lua.h"
#include "lobject.h"
#include "titan/ffi.h"

/* Immutable code capabilities published by each generated module resolver.
 * These descriptors contain no Lua-state-owned data. Each callback pushes
 * exactly one rooted result and may raise; capture indexes are zero based. */
#define TITAN_TRANSFER_MANIFEST_SYMBOL "__titan_transfer_manifest"
#define TITAN_TRANSFER_SOURCE 0u
#define TITAN_TRANSFER_ADAPTER 1u

typedef struct TitanTransferEntry {
    void *native;
    lua_CFunction coercive;
    lua_CFunction strict;
    unsigned capture_count;
    const unsigned char *boxed;
    void (*project)(lua_State *, CClosure *, unsigned);
    void (*restore_capture)(lua_State *, Udata *, unsigned, int);
    void (*restore)(lua_State *, Udata *, int);
    unsigned kind;
} TitanTransferEntry;

typedef struct TitanTransferModule {
    const char *name;
    Udata *(*init)(lua_State *);
    TitanModuleSymbols symbols;
    unsigned entry_count;
    const TitanTransferEntry *entries;
} TitanTransferModule;

/* The caller must publish the empty graph into its cleanup owner before encode
 * can raise. A graph is encoded once and is immutable afterwards. It retains
 * only copied native data, immutable code capabilities, and box ordinals.
 * Decode pushes one semantic value and uses only destination-state GC roots.
 * Both operations require an enclosing owning-state protected error boundary. */
/* The opaque graph API is declared in titan/ffi.h for trusted Titan callers. */

#endif
