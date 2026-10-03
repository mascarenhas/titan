#ifndef TITAN_STRING_FORMAT_NATIVE_H
#define TITAN_STRING_FORMAT_NATIVE_H

#include <float.h>
#include <stdio.h>
#include "lua.h"

/* The controlled CLANG64/UCRT Lua build includes lprefix.h before its C
 * headers. Its _XOPEN_SOURCE selects MinGW's ANSI printf implementation.
 * Keep that formatting dialect with a bounded call, without changing the
 * feature macros of every generated translation unit. */
#if defined(__MINGW32__) && defined(_UCRT)
#define titan_string_snprintf __mingw_snprintf
#else
#define titan_string_snprintf snprintf
#endif

/* These are the exact configuration decisions in Lua 5.5's lstrlib.c.
 * The hexadecimal conversion itself remains implemented in Titan. */
#if !defined(lua_number2strx)
enum { TITAN_STRING_LUA_HEX_FALLBACK = 1 };
#else
enum { TITAN_STRING_LUA_HEX_FALLBACK = 0 };
#endif
enum {
    TITAN_STRING_HEX_LEADING_BITS = (l_floatatt(MANT_DIG) - 1) % 4 + 1
};

#endif
