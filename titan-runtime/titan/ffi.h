#ifndef TITAN_FFI_H
#define TITAN_FFI_H

typedef void titan_ffi_void;
typedef _Bool titan_ffi_bool;
typedef char titan_ffi_char;
typedef signed char titan_ffi_signed_char;
typedef unsigned char titan_ffi_unsigned_char;
typedef short titan_ffi_short;
typedef unsigned short titan_ffi_unsigned_short;
typedef int titan_ffi_int;
typedef unsigned int titan_ffi_unsigned_int;
typedef long titan_ffi_long;
typedef unsigned long titan_ffi_unsigned_long;
typedef long long titan_ffi_long_long;
typedef unsigned long long titan_ffi_unsigned_long_long;
typedef float titan_ffi_float;
typedef double titan_ffi_double;

typedef struct lua_State lua_State;
typedef struct TValue TValue;

#endif
