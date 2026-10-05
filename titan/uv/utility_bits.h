#ifndef TITAN_UV_UTILITY_BITS_H
#define TITAN_UV_UTILITY_BITS_H
#include <limits.h>
#include <stdint.h>
#include <lua.h>

/* The low-level API exposes uint64_t as a signed Lua integer bit pattern. */
typedef char titan_uv_utility_u64_width_check[
    sizeof(lua_Integer) * CHAR_BIT == 64 &&
    sizeof(uint64_t) * CHAR_BIT == 64 &&
    LUA_MAXINTEGER == INT64_MAX &&
    LUA_MININTEGER == INT64_MIN &&
    (lua_Integer) UINT64_MAX == (lua_Integer) -1 ? 1 : -1];
#endif
