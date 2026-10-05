#ifndef TITAN_UV_VERSION_NATIVE_H
#define TITAN_UV_VERSION_NATIVE_H
#include <uv.h>
#if UV_VERSION_HEX < 0x013401
#error "Titan's public uv binding requires libuv 1.52.1 or newer"
#endif
#endif
