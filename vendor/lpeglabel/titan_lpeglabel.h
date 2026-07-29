/*
** Private opener for Titan's embedded LPegLabel engine.
**
** This header is an internal standard-library build input. It is neither
** staged in the Titan SDK nor installed as a public header.
*/

#if !defined(titan_lpeglabel_h)
#define titan_lpeglabel_h

#include "lua.h"

#if defined(__GNUC__) || defined(__clang__)
#define TITAN_LPEGLABEL_HIDDEN __attribute__((visibility("hidden")))
#else
#define TITAN_LPEGLABEL_HIDDEN
#endif

#if defined(__cplusplus)
extern "C" {
#endif

TITAN_LPEGLABEL_HIDDEN int titan_lpeglabel_open(lua_State *L);

#if defined(__cplusplus)
}
#endif

#endif
