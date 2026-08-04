#ifndef TITAN_FFI_H
#define TITAN_FFI_H

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
#define TITAN_TRACE_APPEND_KEY "4f895b66-bae0-4e97-afb3-83a31f2f9e96"
#define TITAN_MAIN_BOOTSTRAP_KEY "41c48a97-55a5-4514-a76f-79ab028ae6e0"
#define TITAN_MAIN_ARGC_KEY "fd9c8d85-f521-4052-92e6-8af5c349e5bb"
#define TITAN_MAIN_ARGV_KEY "fc1376f3-2cb7-48d4-969c-c02df930cf68"

typedef void titan_ffi_void;
typedef void *titan_ffi_void_ptr;
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
typedef long double titan_ffi_long_double;

typedef struct lua_State lua_State;
typedef struct TValue TValue;
typedef struct Udata Udata;

TValue lua_totvalue(lua_State *L, int idx);
void lua_pushtvalue(lua_State *L, TValue v);
void *lua_togco(lua_State *L, int idx);
lua_State *titan_newthread(lua_State *L);

#endif
