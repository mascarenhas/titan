#ifndef TITAN_UV_DATA_NATIVE_H
#define TITAN_UV_DATA_NATIVE_H
#include <uv.h>
#include <lua.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>

typedef char titan_uv_data_u64_width_check[
    sizeof(lua_Integer) * CHAR_BIT == 64 &&
    sizeof(uint64_t) * CHAR_BIT == 64 &&
    LUA_MAXINTEGER == INT64_MAX && LUA_MININTEGER == INT64_MIN &&
    (lua_Integer) UINT64_MAX == (lua_Integer) -1 ? 1 : -1];

/* Select the address of an anonymous native union without copying storage. */
static inline const struct sockaddr* titan_uv_data_address(
    const uv_interface_address_t* entry, int netmask) {
  return netmask ? (const struct sockaddr*) &entry->netmask
                 : (const struct sockaddr*) &entry->address;
}
#endif
