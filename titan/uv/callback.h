#ifndef TITAN_UV_FOUNDATION_CALLBACK_H
#define TITAN_UV_FOUNDATION_CALLBACK_H
#include <titan/ffi.h>
/* Caller reserves one scratch slot before entering libuv. The exact public
 * record userdata is a traced root through the native callback's last action. */
static inline void titan_uv_push_owner(lua_State *L, Udata *owner) {
  TValue value;
  setuvalue(L, &value, owner);
  lua_pushtvalue(L, value);
}
#endif
