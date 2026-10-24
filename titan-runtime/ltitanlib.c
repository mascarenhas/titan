#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0602
#endif

#include "lua.h"
#include "lauxlib.h"

#if defined(_WIN32)
#include "titan.h"
#include "titan_winloader.h"
#else
#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TITAN_BACKTRACE_KEY "57d80578-2534-4856-ad3b-bde8cba4c445"
#define TITAN_TRACE_PINNED "5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"
#define TITAN_LAZY_LIBS_KEY "b03f87d2-aea4-407c-87df-054d5be15ef2"
#define TITAN_LAZY_GLOBAL_LIBS_KEY "3f6cae7b-8aeb-42eb-9f72-a978cfe96f7c"

#if defined(__GNUC__)
#define titan_cast_func(t, p) (__extension__(t)(p))
#else
#define titan_cast_func(t, p) ((t)(p))
#endif

static void push_libs(lua_State *L, const char *registry_key) {
  lua_pushstring(L, registry_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushstring(L, registry_key);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

static int push_loader_error(lua_State *L, const char *error,
                             const char *stage) {
  lua_pushnil(L);
  lua_pushstring(L, error != NULL ? error : "dynamic loader error");
  lua_pushstring(L, stage);
  return 3;
}

static int push_path_error(lua_State *L, const char *filename,
                           const char *error) {
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", filename,
                  error != NULL ? error : "dynamic loader error");
  lua_pushliteral(L, "open");
  return 3;
}

static int push_symbol(lua_State *L, void *lib, const char *symbol,
                       const char *requested_filename) {
  void *raw;
  const char *error;

#if defined(_WIN32)
  raw = titan_cast_func(void *, GetProcAddress((HMODULE)lib, symbol));
  if (raw == NULL) {
    DWORD code = GetLastError();
    lua_pushnil(L);
    titan_win_loader_error(L, "cannot resolve symbol", symbol, code);
    lua_pushfstring(L, "%s: %s", requested_filename, lua_tostring(L, -1));
    lua_remove(L, -2);
    lua_pushliteral(L, "init");
    return 3;
  }
  error = NULL;
#else
  dlerror();
  raw = dlsym(lib, symbol);
  error = dlerror();
#endif
  if (error != NULL) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", requested_filename, error);
    lua_pushliteral(L, "init");
    return 3;
  }
  lua_pushcfunction(L, titan_cast_func(lua_CFunction, raw));
  return 1;
}

#if defined(_WIN32)
static int windows_open_error(lua_State *L) {
  /* titan_win_load_library leaves its diagnostic at the top. */
  lua_pushnil(L);
  lua_insert(L, -2);
  lua_pushliteral(L, "open");
  return 3;
}

static int push_abi_value(lua_State *L, void *lib, const char *symbol) {
  typedef const char *(*titan_abi_value_fn)(void);
  FARPROC raw = GetProcAddress((HMODULE)lib, symbol);
  const char *value;
  if (raw == NULL) {
    DWORD code = GetLastError();
    lua_pushnil(L);
    titan_win_loader_error(L, "cannot resolve ABI query", symbol, code);
    lua_pushliteral(L, "init");
    return 3;
  }
  value = titan_cast_func(titan_abi_value_fn, raw)();
  if (value == NULL)
    return push_loader_error(L, "native ABI query returned NULL", "abi");
  lua_pushstring(L, value);
  return 1;
}

static int canonical_module(lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1));
  return 1;
}

/* Never wrap this plain-C entry as a lua_CFunction. Its result is copied into
** Lua while the provider's retained Windows mapping owns the original bytes. */
static int abivalue(lua_State *L) {
  const char *filename = titan_win_loader_string(L, 1);
  const char *symbol = titan_win_loader_string(L, 2);
  HMODULE lib = titan_win_load_library(L, filename, TITAN_LAZY_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  return push_abi_value(L, lib, symbol);
}
#endif

/* Internal compiler helper. Titan interfaces are ordinary Lua C functions,
** but package.loadlib maps with RTLD_NOW. Map the image lazily and locally so
** the compiler can inspect its ABI and type symbols without initializing it.
** The registry remembers handles for reuse; no finalizer calls dlclose, so
** mapped Titan interfaces remain available for the process lifetime. */
static int lazyload(lua_State *L) {
#if defined(_WIN32)
  const char *filename = titan_win_loader_string(L, 1);
  const char *symbol = titan_win_loader_string(L, 2);
  HMODULE lib = titan_win_load_library(L, filename, TITAN_LAZY_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  return push_symbol(L, lib, symbol, filename);
#else
  const char *filename = luaL_checkstring(L, 1);
  const char *symbol = luaL_checkstring(L, 2);
  void *lib;
  const char *error;

  push_libs(L, TITAN_LAZY_LIBS_KEY);
  lua_pushvalue(L, 1);
  lua_rawget(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lib = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);
    if (lib == NULL) {
      error = dlerror();
      lua_pop(L, 1);
      return push_loader_error(L, error, "open");
    }
    lua_pushvalue(L, 1);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
  } else {
    lib = lua_touserdata(L, -1);
    lua_pop(L, 1);
  }

  lua_pop(L, 1);
  return push_symbol(L, lib, symbol, filename);
#endif
}

/* Internal Lua-shim helper. Canonical path keys make aliases share one entry
** in this state's private cache, but the cache remains distinct from both
** Lua's C-library handles and the compiler-only lazy/local cache above. The
** first request in each Lua state therefore always performs a lazy/global
** dlopen, which can promote an image that was mapped locally beforehand.
** Handles are stored as light userdata and are deliberately never closed. */
/* Implementation notes: doc/implementation/lua-interop-internals.md#4-generated-shim-lazyglobal-loading-and-promotion */
static int lazyglobalload(lua_State *L) {
#if defined(_WIN32)
  const char *symbol = titan_win_loader_string(L, 2);
  const char *module = titan_win_loader_string(L, 3);
  const char *filename;
  HMODULE lib;
  const char *query, *actual;
  int results;
  luaL_checkstack(L, 6, "looking up a canonical Titan module");
  lua_pushfstring(L, "Titan module %s", module);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_isnil(L, -1)) {
    const TitanModuleData *data;
    if (lua_type(L, -1) != LUA_TUSERDATA ||
        lua_rawlen(L, -1) < sizeof(TitanModuleData))
      return push_loader_error(L, "invalid canonical Titan module state", "init");
    data = (const TitanModuleData *)lua_touserdata(L, -1);
    if (data->symbols == NULL)
      return push_loader_error(L, "invalid canonical Titan module descriptor", "init");
    lua_pushcclosure(L, canonical_module, 1);
    return 1;
  }
  lua_pop(L, 1);
  if (lua_isnoneornil(L, 1))
    return push_loader_error(L, "Titan provider was not found", "open");
  filename = titan_win_loader_string(L, 1);
  lib = titan_win_load_library(L, filename, TITAN_LAZY_GLOBAL_LIBS_KEY);
  if (lib == NULL) return windows_open_error(L);
  if (strncmp(symbol, "luaopen_", 8) != 0)
    return push_loader_error(L, "Titan shim requires a luaopen_ entry", "init");
  query = lua_pushfstring(L, "%s_abi_value", symbol + 8);
  results = push_abi_value(L, lib, query);
  if (results != 1) return results;
  actual = lua_tostring(L, -1);
  if (strcmp(actual, TITAN_ABI_VERSION) != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "Titan compiled module '%s' ABI mismatch: expected "
        TITAN_ABI_VERSION " but found %s", filename, actual);
    lua_pushliteral(L, "abi");
    return 3;
  }
  lua_pop(L, 2); /* ABI query name and copied value */
  return push_symbol(L, lib, symbol, filename);
#else
  const char *filename = luaL_checkstring(L, 1);
  const char *symbol = luaL_checkstring(L, 2);
  char *canonical;
  void *lib;
  const char *error;
  int error_number;

  errno = 0;
  canonical = realpath(filename, NULL);
  if (canonical == NULL) {
    error_number = errno;
    return push_path_error(L, filename,
                           error_number != 0 ? strerror(error_number)
                                             : "cannot resolve path");
  }

  push_libs(L, TITAN_LAZY_GLOBAL_LIBS_KEY);
  lua_pushstring(L, canonical);
  lua_rawget(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    /* realpath is both the cache identity and the image we actually open.
    ** A bare relative filename (for example one returned by a ?.so package
    ** template) must not be reinterpreted through the platform loader path. */
    lib = dlopen(canonical, RTLD_LAZY | RTLD_GLOBAL);
    if (lib == NULL) {
      error = dlerror();
      lua_pop(L, 1);
      free(canonical);
      return push_path_error(L, filename, error);
    }
    lua_pushstring(L, canonical);
    lua_pushlightuserdata(L, lib);
    lua_rawset(L, -3);
  } else {
    lib = lua_touserdata(L, -1);
    lua_pop(L, 1);
  }

  lua_pop(L, 1);
  free(canonical);
  return push_symbol(L, lib, symbol, filename);
#endif
}

static int getbacktrace(lua_State *L) {
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  return 1;
}

/* Pin the trace slot: the next error's message handler will KEEP the existing
** TITAN_BACKTRACE_KEY slot instead of regenerating it (one-shot; the handler
** clears the pin). This is the re-raise discipline surfaced for testing;
** catch/re-raise code drives it from generated C. */
static int pintrace(lua_State *L) {
  lua_pushliteral(L, TITAN_TRACE_PINNED);
  lua_pushboolean(L, 1);
  lua_rawset(L, LUA_REGISTRYINDEX);
  return 0;
}

/* Clear the trace slot (and any pin), so the next error regenerates it. */
static int cleartrace(lua_State *L) {
  lua_pushliteral(L, TITAN_BACKTRACE_KEY);
  lua_pushnil(L);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_pushliteral(L, TITAN_TRACE_PINNED);
  lua_pushnil(L);
  lua_rawset(L, LUA_REGISTRYINDEX);
  return 0;
}

/* Private compiler helper: SHA-256 of a Lua byte string, returned as the
** 32-byte binary digest. Byte-for-byte equal to titan-compiler.sha256.
** Implementation notes: doc/implementation/driver.md#native-compiler-support */
#define TITAN_SHA_ROTR(x, n) ((uint32_t)(((x) >> (n)) | ((x) << (32 - (n)))))

static const uint32_t titan_sha256_k[64] = {
  0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
  0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
  0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
  0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
  0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
  0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
  0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
  0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
  0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
  0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
  0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
  0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
  0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static void titan_sha256_block(uint32_t state[8], const unsigned char *block) {
  uint32_t w[64];
  uint32_t a, b, c, d, e, f, g, h;
  int i;
  for (i = 0; i < 16; i++)
    w[i] = ((uint32_t)block[4 * i] << 24) | ((uint32_t)block[4 * i + 1] << 16) |
           ((uint32_t)block[4 * i + 2] << 8) | (uint32_t)block[4 * i + 3];
  for (i = 16; i < 64; i++) {
    uint32_t s0 = TITAN_SHA_ROTR(w[i - 15], 7) ^ TITAN_SHA_ROTR(w[i - 15], 18) ^
                  (w[i - 15] >> 3);
    uint32_t s1 = TITAN_SHA_ROTR(w[i - 2], 17) ^ TITAN_SHA_ROTR(w[i - 2], 19) ^
                  (w[i - 2] >> 10);
    w[i] = (uint32_t)(w[i - 16] + s0 + w[i - 7] + s1);
  }
  a = state[0]; b = state[1]; c = state[2]; d = state[3];
  e = state[4]; f = state[5]; g = state[6]; h = state[7];
  for (i = 0; i < 64; i++) {
    uint32_t sum1 = TITAN_SHA_ROTR(e, 6) ^ TITAN_SHA_ROTR(e, 11) ^ TITAN_SHA_ROTR(e, 25);
    uint32_t choose = (e & f) ^ ((uint32_t)~e & g);
    uint32_t temp1 = (uint32_t)(h + sum1 + choose + titan_sha256_k[i] + w[i]);
    uint32_t sum0 = TITAN_SHA_ROTR(a, 2) ^ TITAN_SHA_ROTR(a, 13) ^ TITAN_SHA_ROTR(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = (uint32_t)(sum0 + majority);
    h = g; g = f; f = e; e = (uint32_t)(d + temp1);
    d = c; c = b; b = a; a = (uint32_t)(temp1 + temp2);
  }
  state[0] += a; state[1] += b; state[2] += c; state[3] += d;
  state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static int sha256_binary(lua_State *L) {
  uint32_t state[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
  };
  unsigned char tail[128], digest[32];
  const unsigned char *data;
  size_t length, offset, rest, tail_length, i;
  uint64_t bits;
  luaL_checktype(L, 1, LUA_TSTRING);
  data = (const unsigned char *)lua_tolstring(L, 1, &length);
  for (offset = 0; length - offset >= 64; offset += 64)
    titan_sha256_block(state, data + offset);
  rest = length - offset;
  memcpy(tail, data + offset, rest);
  tail[rest] = 0x80;
  tail_length = rest < 56 ? 64 : 128;
  memset(tail + rest + 1, 0, tail_length - rest - 1);
  bits = (uint64_t)length << 3;
  for (i = 0; i < 8; i++)
    tail[tail_length - 1 - i] = (unsigned char)(bits >> (8 * i));
  titan_sha256_block(state, tail);
  if (tail_length == 128) titan_sha256_block(state, tail + 64);
  for (i = 0; i < 8; i++) {
    digest[4 * i] = (unsigned char)(state[i] >> 24);
    digest[4 * i + 1] = (unsigned char)(state[i] >> 16);
    digest[4 * i + 2] = (unsigned char)(state[i] >> 8);
    digest[4 * i + 3] = (unsigned char)state[i];
  }
  lua_pushlstring(L, (const char *)digest, sizeof digest);
  return 1;
}

#if !defined(_WIN32)
/* Private compiler helpers: GNU Make jobserver participation for native job
** batches. A client owns private open-file descriptions of the parent's
** token channel (the FIFO path, or a Linux /proc reopen of an inherited
** pipe), so nonblocking reads never change an inherited shared description.
** The ledger records the exact borrowed bytes; release and close write those
** bytes back, and collection returns any that remain.
** Implementation notes: doc/implementation/driver.md#gnu-make-jobserver-participation */
#define TITAN_JOBSERVER_TYPE "titan.jobserver"
#define TITAN_SIGNAL_GUARD_TYPE "titan.signalguard"

typedef struct TitanJobserver {
  int read_fd;
  int write_fd;
  size_t held;
  size_t capacity;
  unsigned char *bytes;
} TitanJobserver;

static int push_errno(lua_State *L, const char *what, int error_number) {
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", what, strerror(error_number));
  return 2;
}

static int push_failure(lua_State *L, const char *message) {
  lua_pushnil(L);
  lua_pushstring(L, message);
  return 2;
}

static int same_channel(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static int open_private(const char *path, int flags, const struct stat *expected,
                        int *result) {
  struct stat actual;
  int fd;
  do fd = open(path, flags | O_NONBLOCK | O_CLOEXEC);
  while (fd < 0 && errno == EINTR);
  if (fd < 0) return errno;
  if (fstat(fd, &actual) != 0) {
    int error_number = errno;
    close(fd);
    return error_number;
  }
  if (!S_ISFIFO(actual.st_mode) ||
      (expected != NULL && !same_channel(expected, &actual))) {
    close(fd);
    return EINVAL;
  }
  *result = fd;
  return 0;
}

static int write_token(int fd, unsigned char byte) {
  for (;;) {
    ssize_t count = write(fd, &byte, 1);
    if (count == 1) return 0;
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd writable;
      writable.fd = fd;
      writable.events = POLLOUT;
      writable.revents = 0;
      if (poll(&writable, 1, -1) < 0 && errno != EINTR) return errno;
      continue;
    }
    return count < 0 ? errno : EIO;
  }
}

static int jobserver_shutdown(TitanJobserver *client) {
  int failure = 0;
  while (client->held > 0 && client->write_fd >= 0) {
    failure = write_token(client->write_fd, client->bytes[client->held - 1]);
    if (failure != 0) break;
    client->held--;
  }
  client->held = 0;
  if (client->read_fd >= 0) close(client->read_fd);
  if (client->write_fd >= 0) close(client->write_fd);
  client->read_fd = client->write_fd = -1;
  free(client->bytes);
  client->bytes = NULL;
  client->capacity = 0;
  return failure;
}

static TitanJobserver *check_jobserver(lua_State *L, int index) {
  TitanJobserver *client =
      (TitanJobserver *)luaL_checkudata(L, index, TITAN_JOBSERVER_TYPE);
  if (client->read_fd < 0) luaL_error(L, "attempt to use a closed jobserver client");
  return client;
}

/* _jobserver_open("fifo", path) or _jobserver_open("pipe", read_fd, write_fd)
** -> client | nil, reason. */
static int jobserver_open(lua_State *L) {
  const char *kind = luaL_checkstring(L, 1);
  TitanJobserver *client =
      (TitanJobserver *)lua_newuserdatauv(L, sizeof(TitanJobserver), 0);
  int error_number;
  client->read_fd = client->write_fd = -1;
  client->held = client->capacity = 0;
  client->bytes = NULL;
  luaL_setmetatable(L, TITAN_JOBSERVER_TYPE);
  if (strcmp(kind, "fifo") == 0) {
    const char *path = luaL_checkstring(L, 2);
    struct stat channel;
    if (stat(path, &channel) != 0)
      return push_errno(L, "cannot inspect the jobserver FIFO", errno);
    if (!S_ISFIFO(channel.st_mode))
      return push_failure(L, "the jobserver FIFO path is not a FIFO");
    error_number = open_private(path, O_RDONLY, &channel, &client->read_fd);
    if (error_number == 0)
      error_number = open_private(path, O_WRONLY, &channel, &client->write_fd);
    if (error_number != 0) {
      jobserver_shutdown(client);
      return push_errno(L, "cannot open the jobserver FIFO", error_number);
    }
  } else if (strcmp(kind, "pipe") == 0) {
    lua_Integer inherited_read = luaL_checkinteger(L, 2);
    lua_Integer inherited_write = luaL_checkinteger(L, 3);
    struct stat read_channel, write_channel;
    if (inherited_read < 0 || inherited_write < 0 ||
        inherited_read > INT_MAX || inherited_write > INT_MAX)
      return push_failure(L, "the jobserver descriptors were not passed to "
                             "this command");
    if (fstat((int)inherited_read, &read_channel) != 0 ||
        fstat((int)inherited_write, &write_channel) != 0)
      return push_failure(L, "the jobserver descriptors are closed");
    if (!S_ISFIFO(read_channel.st_mode) || !S_ISFIFO(write_channel.st_mode) ||
        !same_channel(&read_channel, &write_channel))
      return push_failure(L, "the jobserver descriptors are not one pipe");
#if defined(__linux__)
    {
      char path[64];
      snprintf(path, sizeof path, "/proc/self/fd/%d", (int)inherited_read);
      error_number = open_private(path, O_RDONLY, &read_channel, &client->read_fd);
      if (error_number == 0) {
        snprintf(path, sizeof path, "/proc/self/fd/%d", (int)inherited_write);
        error_number =
            open_private(path, O_WRONLY, &read_channel, &client->write_fd);
      }
      if (error_number != 0) {
        jobserver_shutdown(client);
        return push_errno(L, "cannot reopen the jobserver pipe", error_number);
      }
    }
#else
    return push_failure(L, "this platform cannot reopen an inherited "
                           "jobserver pipe privately");
#endif
  } else {
    return luaL_argerror(L, 1, "expected \"fifo\" or \"pipe\"");
  }
  return 1;
}

/* client:acquire() -> true (one exact byte borrowed) | false (no token now)
** | nil, reason. */
static int jobserver_acquire(lua_State *L) {
  TitanJobserver *client = check_jobserver(L, 1);
  unsigned char byte;
  ssize_t count;
  if (client->held == client->capacity) {
    size_t capacity = client->capacity == 0 ? 8 : client->capacity * 2;
    unsigned char *bytes;
    if (capacity < client->capacity)
      return push_failure(L, "jobserver token ledger overflow");
    bytes = (unsigned char *)realloc(client->bytes, capacity);
    if (bytes == NULL) return push_failure(L, "cannot grow the jobserver token ledger");
    client->bytes = bytes;
    client->capacity = capacity;
  }
  do count = read(client->read_fd, &byte, 1);
  while (count < 0 && errno == EINTR);
  if (count == 1) {
    client->bytes[client->held++] = byte;
    lua_pushboolean(L, 1);
    return 1;
  }
  if (count == 0) return push_failure(L, "the jobserver was closed by its owner");
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    lua_pushboolean(L, 0);
    return 1;
  }
  return push_errno(L, "cannot read a jobserver token", errno);
}

/* client:release() -> true | nil, reason: returns the most recent byte. */
static int jobserver_release(lua_State *L) {
  TitanJobserver *client = check_jobserver(L, 1);
  int error_number;
  if (client->held == 0) return push_failure(L, "no jobserver token is held");
  error_number = write_token(client->write_fd, client->bytes[client->held - 1]);
  if (error_number != 0)
    return push_errno(L, "cannot return a jobserver token", error_number);
  client->held--;
  lua_pushboolean(L, 1);
  return 1;
}

static int jobserver_held(lua_State *L) {
  TitanJobserver *client =
      (TitanJobserver *)luaL_checkudata(L, 1, TITAN_JOBSERVER_TYPE);
  lua_pushinteger(L, (lua_Integer)client->held);
  return 1;
}

/* client:close() -> true | nil, reason. Returns every borrowed byte. */
static int jobserver_close(lua_State *L) {
  TitanJobserver *client =
      (TitanJobserver *)luaL_checkudata(L, 1, TITAN_JOBSERVER_TYPE);
  size_t held = client->held;
  int error_number = jobserver_shutdown(client);
  if (error_number != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "cannot return %d jobserver token(s): %s", (int)held,
                    strerror(error_number));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int jobserver_gc(lua_State *L) {
  jobserver_shutdown((TitanJobserver *)luaL_checkudata(L, 1, TITAN_JOBSERVER_TYPE));
  return 0;
}

/* A temporary INT/TERM/HUP action only records the first signal and wakes
** _jobserver_wait; the batch stops launching, drains, returns tokens, and
** restores the prior actions (including Lua's SIGINT handler) before the
** caller re-raises. Ignored signals stay ignored. */
static const int titan_guarded_signals[] = { SIGINT, SIGTERM, SIGHUP };
#define TITAN_GUARDED_SIGNALS \
  ((int)(sizeof titan_guarded_signals / sizeof titan_guarded_signals[0]))
static struct sigaction titan_saved_actions[TITAN_GUARDED_SIGNALS];
static int titan_saved_valid[TITAN_GUARDED_SIGNALS];
static volatile sig_atomic_t titan_cancel_signal = 0;
static volatile sig_atomic_t titan_wake_write_fd = -1;
static int titan_wake_read_fd = -1;
static int titan_signal_guarded = 0;

static void titan_cancel_handler(int signo) {
  int saved_errno = errno;
  int fd = (int)titan_wake_write_fd;
  if (titan_cancel_signal == 0) titan_cancel_signal = signo;
  if (fd >= 0) {
    unsigned char byte = 1;
    ssize_t ignored = write(fd, &byte, 1);
    (void)ignored;
  }
  errno = saved_errno;
}

static void drain_wake_pipe(void) {
  unsigned char buffer[64];
  if (titan_wake_read_fd < 0) return;
  while (read(titan_wake_read_fd, buffer, sizeof buffer) > 0) {}
}

static int restore_signal_actions(void) {
  int i, signo;
  if (!titan_signal_guarded) return 0;
  for (i = 0; i < TITAN_GUARDED_SIGNALS; i++) {
    if (titan_saved_valid[i])
      sigaction(titan_guarded_signals[i], &titan_saved_actions[i], NULL);
    titan_saved_valid[i] = 0;
  }
  signo = (int)titan_cancel_signal;
  titan_cancel_signal = 0;
  if (titan_wake_write_fd >= 0) close((int)titan_wake_write_fd);
  titan_wake_write_fd = -1;
  if (titan_wake_read_fd >= 0) close(titan_wake_read_fd);
  titan_wake_read_fd = -1;
  titan_signal_guarded = 0;
  return signo;
}

static int set_private_flags(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
         fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

/* _signal_guard() -> guard | nil, reason. */
static int signal_guard(lua_State *L) {
  struct sigaction action;
  unsigned char *owner;
  int fds[2], i;
  if (titan_signal_guarded)
    return push_failure(L, "a native job signal guard is already active");
  owner = (unsigned char *)lua_newuserdatauv(L, 1, 0);
  *owner = 0;
  luaL_setmetatable(L, TITAN_SIGNAL_GUARD_TYPE);
  if (pipe(fds) != 0) return push_errno(L, "cannot create the signal wake pipe", errno);
  if (!set_private_flags(fds[0]) || !set_private_flags(fds[1])) {
    int error_number = errno;
    close(fds[0]);
    close(fds[1]);
    return push_errno(L, "cannot configure the signal wake pipe", error_number);
  }
  titan_wake_read_fd = fds[0];
  titan_wake_write_fd = fds[1];
  titan_cancel_signal = 0;
  memset(&action, 0, sizeof action);
  action.sa_handler = titan_cancel_handler;
  sigemptyset(&action.sa_mask);
  for (i = 0; i < TITAN_GUARDED_SIGNALS; i++)
    sigaddset(&action.sa_mask, titan_guarded_signals[i]);
  action.sa_flags = SA_RESTART;
  for (i = 0; i < TITAN_GUARDED_SIGNALS; i++) {
    struct sigaction *saved = &titan_saved_actions[i];
    titan_saved_valid[i] = 0;
    if (sigaction(titan_guarded_signals[i], NULL, saved) != 0) continue;
    if (!(saved->sa_flags & SA_SIGINFO) && saved->sa_handler == SIG_IGN) continue;
    if (sigaction(titan_guarded_signals[i], &action, NULL) == 0) titan_saved_valid[i] = 1;
  }
  titan_signal_guarded = 1;
  *owner = 1;
  return 1;
}

/* guard:restore() -> signal number | nil. Idempotent. */
static int signal_guard_restore(lua_State *L) {
  unsigned char *owner =
      (unsigned char *)luaL_checkudata(L, 1, TITAN_SIGNAL_GUARD_TYPE);
  int signo = 0;
  if (*owner) signo = restore_signal_actions();
  *owner = 0;
  if (signo != 0) lua_pushinteger(L, signo);
  else lua_pushnil(L);
  return 1;
}

static int signal_guard_gc(lua_State *L) {
  unsigned char *owner =
      (unsigned char *)luaL_checkudata(L, 1, TITAN_SIGNAL_GUARD_TYPE);
  if (*owner) restore_signal_actions();
  *owner = 0;
  return 0;
}

static int signal_pending(lua_State *L) {
  if (titan_cancel_signal != 0) lua_pushinteger(L, (lua_Integer)titan_cancel_signal);
  else lua_pushnil(L);
  return 1;
}

static int signal_raise(lua_State *L) {
  lua_Integer signo = luaL_checkinteger(L, 1);
  if (signo <= 0 || signo > INT_MAX) return luaL_argerror(L, 1, "invalid signal");
  if (raise((int)signo) != 0) return push_errno(L, "cannot raise the signal", errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* _jobserver_wait(completion_file, client_or_nil, watch_signals)
** -> "signal", signo | "completion" | "slot" | nil, reason.
** The completion FILE must be unbuffered; nothing is consumed from it. */
static int jobserver_wait(lua_State *L) {
  luaL_Stream *stream = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  TitanJobserver *client = lua_isnoneornil(L, 2) ? NULL : check_jobserver(L, 2);
  int watch_signals = lua_toboolean(L, 3);
  struct pollfd fds[3];
  nfds_t count = 0, token = 0, wake = 0;
  if (stream->closef == NULL) return luaL_error(L, "attempt to use a closed file");
  fds[count].fd = fileno(stream->f);
  fds[count++].events = POLLIN;
  if (client != NULL) {
    token = count;
    fds[count].fd = client->read_fd;
    fds[count++].events = POLLIN;
  }
  if (watch_signals && titan_wake_read_fd >= 0) {
    wake = count;
    fds[count].fd = titan_wake_read_fd;
    fds[count++].events = POLLIN;
  }
  for (;;) {
    nfds_t i;
    if (watch_signals && titan_cancel_signal != 0) {
      lua_pushliteral(L, "signal");
      lua_pushinteger(L, (lua_Integer)titan_cancel_signal);
      return 2;
    }
    for (i = 0; i < count; i++) fds[i].revents = 0;
    if (poll(fds, count, -1) < 0) {
      if (errno == EINTR) continue;
      return push_errno(L, "cannot wait for native jobs", errno);
    }
    if (wake != 0 && fds[wake].revents != 0) drain_wake_pipe();
    if (fds[0].revents & POLLNVAL)
      return push_failure(L, "the native job completion channel is not open");
    if (fds[0].revents != 0) {
      lua_pushliteral(L, "completion");
      return 1;
    }
    if (token != 0 && fds[token].revents != 0) {
      lua_pushliteral(L, "slot");
      return 1;
    }
  }
}

static const luaL_Reg jobserver_methods[] = {
  { "acquire", jobserver_acquire },
  { "release", jobserver_release },
  { "held", jobserver_held },
  { "close", jobserver_close },
  { NULL, NULL }
};
#endif

static const luaL_Reg titanlib[] = {
  { "backtrace", getbacktrace },
  { "pin", pintrace },
  { "clear", cleartrace },
  { "_loadlib", lazyload },
  { "_loadlibglobal", lazyglobalload },
  { "_sha256_binary", sha256_binary },
#if defined(_WIN32)
  { "_abivalue", abivalue },
#else
  { "_jobserver_open", jobserver_open },
  { "_jobserver_wait", jobserver_wait },
  { "_signal_guard", signal_guard },
  { "_signal_pending", signal_pending },
  { "_signal_raise", signal_raise },
#endif
  { NULL, NULL }
};

LUAMOD_API int luaopen_titan(lua_State *L) {
#if !defined(_WIN32)
  if (luaL_newmetatable(L, TITAN_JOBSERVER_TYPE)) {
    luaL_newlib(L, jobserver_methods);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, jobserver_gc);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, jobserver_gc);
    lua_setfield(L, -2, "__close");
  }
  lua_pop(L, 1);
  if (luaL_newmetatable(L, TITAN_SIGNAL_GUARD_TYPE)) {
    lua_newtable(L);
    lua_pushcfunction(L, signal_guard_restore);
    lua_setfield(L, -2, "restore");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, signal_guard_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
#endif
  luaL_newlib(L, titanlib);
  return 1;
}
