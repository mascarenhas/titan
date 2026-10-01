/* Private Windows compiler filesystem helpers.
** Include only in the Windows branch of ltitanlib.c, after lua.h/lauxlib.h.
** Link bcrypt; all other calls are provided by Windows kernel32.
** These helpers do not perform dynamic loading or depend on libuv.
*/
#ifndef TITAN_LTITAN_WINFS_H
#define TITAN_LTITAN_WINFS_H

#if !defined(_WIN32)
#error "ltitan_winfs.h is Windows-only"
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* Win32's extended path limit includes the terminator. This does not silently
** add an extended-path prefix or change ordinary Win32 pathname semantics.
** The executable's longPathAware setting still controls ordinary long paths.
*/
#define TITAN_WINFS_PATH_CAPACITY 32768
#define TITAN_WINFS_RANDOM_BYTES 16
#define TITAN_WINFS_RETRIES 32
#define TITAN_WINFS_RESERVATION_MT "titan.compiler.winfs.reservation"

typedef struct titan_winfs_reservation {
  HANDLE handle;
  WCHAR path[1];
} titan_winfs_reservation;

/* Ordinarily the handle is closed before returning. The to-be-closed guard
** also covers the unexpected CloseHandle failure path: subsequent Lua error
** allocation/unwinding cannot lose the native owner. No Lua allocation occurs
** in this finalizer. __gc is a second chance if closing still failed at return.
*/
static int titan_winfs_close_reservation(lua_State *L) {
  titan_winfs_reservation *reservation =
      (titan_winfs_reservation *)luaL_testudata(L, 1, TITAN_WINFS_RESERVATION_MT);
  if (reservation == NULL) return 0;
  if (reservation->handle != INVALID_HANDLE_VALUE &&
      CloseHandle(reservation->handle)) {
    reservation->handle = INVALID_HANDLE_VALUE;
    DeleteFileW(reservation->path);
  }
  return 0;
}

static int titan_winfs_error(lua_State *L, const char *operation, DWORD error) {
  WCHAR wide[512];
  char detail[2048];
  char message[2304];
  DWORD length;
  int converted;

  length = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                         NULL, error, 0, wide,
                         (DWORD)(sizeof(wide) / sizeof(wide[0])), NULL);
  while (length != 0 && (wide[length - 1] == L'\r' || wide[length - 1] == L'\n'))
    --length;
  converted = length == 0 ? 0 : WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide, (int)length, detail,
      (int)sizeof(detail) - 1, NULL, NULL);
  detail[converted > 0 ? converted : 0] = '\0';
  if (detail[0] != '\0')
    snprintf(message, sizeof(message), "%s: Windows error %lu (%s)",
             operation, (unsigned long)error, detail);
  else
    snprintf(message, sizeof(message), "%s: Windows error %lu",
             operation, (unsigned long)error);
  lua_pushnil(L);
  lua_pushstring(L, message);
  lua_pushinteger(L, (lua_Integer)error);
  return 3;
}

static int titan_winfs_invalid(lua_State *L, const char *operation,
                               const char *detail, DWORD error) {
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", operation, detail);
  lua_pushinteger(L, (lua_Integer)error);
  return 3;
}

/* Lua-owned scratch memory is rooted on the stack. No malloc-owned allocation
** can be lost if a later Lua allocation raises. Input strings must be actual
** UTF-8 strings, not numbers coerced through luaL_checkstring.
*/
static WCHAR *titan_winfs_path(lua_State *L, int index, DWORD *error) {
  const char *path;
  size_t length;
  int count;
  WCHAR *wide;

  if (lua_type(L, index) != LUA_TSTRING) {
    *error = ERROR_INVALID_PARAMETER;
    return NULL;
  }
  path = lua_tolstring(L, index, &length);
  if (length == 0 || memchr(path, '\0', length) != NULL) {
    *error = ERROR_INVALID_NAME;
    return NULL;
  }
  if (length > INT_MAX) {
    *error = ERROR_FILENAME_EXCED_RANGE;
    return NULL;
  }
  count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path,
                              (int)length, NULL, 0);
  if (count == 0) {
    *error = GetLastError();
    return NULL;
  }
  if (count >= TITAN_WINFS_PATH_CAPACITY) {
    *error = ERROR_FILENAME_EXCED_RANGE;
    return NULL;
  }
  wide = (WCHAR *)lua_newuserdatauv(L, ((size_t)count + 1) * sizeof(WCHAR), 0);
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path,
                        (int)length, wide, count) == 0) {
    *error = GetLastError();
    return NULL;
  }
  wide[count] = L'\0';
  return wide;
}

/* Leave just the UTF-8 Lua string above existing stack entries. This runs
** BEFORE reserving a file; an allocation failure cannot orphan a reservation.
*/
static int titan_winfs_push_path(lua_State *L, const WCHAR *wide, DWORD *error) {
  size_t wide_length = wcslen(wide);
  int count;
  char *utf8;
  count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide,
                            (int)wide_length, NULL, 0, NULL, NULL);
  if (count == 0) {
    *error = GetLastError();
    return 0;
  }
  utf8 = (char *)lua_newuserdatauv(L, (size_t)count, 0);
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide,
                         (int)wide_length, utf8, count, NULL, NULL) == 0) {
    *error = GetLastError();
    return 0;
  }
  lua_pushlstring(L, utf8, (size_t)count);
  lua_remove(L, -2);
  return 1;
}

/* prefix is a directory prefix including its last slash (or a drive-relative
** "C:"). Generated basenames have 128 independent random bits. CREATE_NEW
** makes collisions non-destructive, including collisions with links.
*/
static int titan_winfs_reserve(lua_State *L, const WCHAR *prefix,
                              size_t prefix_length, int directory,
                              const char *operation) {
  static const WCHAR start[] = L".titan-tmp-";
  static const WCHAR end[] = L".tmp";
  static const WCHAR hex[] = L"0123456789abcdef";
  const size_t start_length = sizeof(start) / sizeof(start[0]) - 1;
  const size_t end_length = sizeof(end) / sizeof(end[0]) - 1;
  const size_t suffix_length = start_length + 2 * TITAN_WINFS_RANDOM_BYTES + end_length;
  WCHAR *candidate;
  titan_winfs_reservation *reservation;
  size_t i;
  int attempt;

  if (prefix_length >= TITAN_WINFS_PATH_CAPACITY - suffix_length)
    return titan_winfs_error(L, operation, ERROR_FILENAME_EXCED_RANGE);
  reservation = (titan_winfs_reservation *)lua_newuserdatauv(
      L, offsetof(titan_winfs_reservation, path) +
             (prefix_length + suffix_length + 1) * sizeof(WCHAR), 0);
  reservation->handle = INVALID_HANDLE_VALUE;
  if (luaL_newmetatable(L, TITAN_WINFS_RESERVATION_MT)) {
    lua_pushcfunction(L, titan_winfs_close_reservation);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, titan_winfs_close_reservation);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_toclose(L, -1);
  candidate = reservation->path;
  memcpy(candidate, prefix, prefix_length * sizeof(WCHAR));
  memcpy(candidate + prefix_length, start, start_length * sizeof(WCHAR));
  memcpy(candidate + prefix_length + start_length + 2 * TITAN_WINFS_RANDOM_BYTES,
         end, (end_length + 1) * sizeof(WCHAR));

  for (attempt = 0; attempt < TITAN_WINFS_RETRIES; ++attempt) {
    unsigned char random[TITAN_WINFS_RANDOM_BYTES];
    NTSTATUS status;
    DWORD error;
    HANDLE handle;

    status = BCryptGenRandom(NULL, random, (ULONG)sizeof(random),
                             BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (status < 0) {
      char message[128];
      snprintf(message, sizeof(message),
               "Windows random generator failed (NTSTATUS 0x%08lx)",
               (unsigned long)(ULONG)status);
      return titan_winfs_invalid(L, operation, message, ERROR_GEN_FAILURE);
    }
    for (i = 0; i < sizeof(random); ++i) {
      candidate[prefix_length + start_length + 2 * i] = hex[random[i] >> 4];
      candidate[prefix_length + start_length + 2 * i + 1] = hex[random[i] & 15];
    }
    if (!titan_winfs_push_path(L, candidate, &error))
      return titan_winfs_error(L, operation, error);

    /* No Lua API calls while the handle is live. The complete return string
    ** is already on the stack, and normal success performs no more allocation.
    */
    if (directory) {
      if (CreateDirectoryW(candidate, NULL)) return 1;
      error = GetLastError();
      lua_pop(L, 1);
      if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS)
        return titan_winfs_error(L, operation, error);
      continue;
    }
    handle = CreateFileW(candidate, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle != INVALID_HANDLE_VALUE) {
      reservation->handle = handle;
      if (!CloseHandle(handle)) {
        error = GetLastError();
        /* The armed guard attempts close+unlink on return or unwinding.
        ** Report the original error rather than claiming ownership transfer.
        */
        return titan_winfs_error(L, operation, error);
      }
      reservation->handle = INVALID_HANDLE_VALUE;
      return 1;
    }
    error = GetLastError();
    lua_pop(L, 1);
    if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS)
      return titan_winfs_error(L, operation, error);
  }
  return titan_winfs_error(L, operation, ERROR_FILE_EXISTS);
}

static int titan_winfs_tmpname(lua_State *L) {
  WCHAR *directory;
  DWORD length;
  directory = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINFS_PATH_CAPACITY * sizeof(WCHAR), 0);
  length = GetTempPathW(TITAN_WINFS_PATH_CAPACITY, directory);
  if (length == 0)
    return titan_winfs_error(L, "tmpname", GetLastError());
  if (length >= TITAN_WINFS_PATH_CAPACITY)
    return titan_winfs_error(L, "tmpname", ERROR_FILENAME_EXCED_RANGE);
  /* GetTempPathW supplies the trailing backslash, without testing existence or
  ** permissions; CreateFileW below reports those failures without fallback.
  */
  return titan_winfs_reserve(L, directory, (size_t)length, 0, "tmpname");
}

static int titan_winfs_reserve_sibling(lua_State *L) {
  DWORD error;
  WCHAR *destination;
  int directory;
  size_t length;
  size_t prefix_length = 0;
  size_t i;
  if (!lua_isnoneornil(L, 2) && lua_type(L, 2) != LUA_TBOOLEAN)
    return titan_winfs_invalid(L, "reserve sibling",
                               "directory must be a boolean", ERROR_INVALID_PARAMETER);
  directory = lua_toboolean(L, 2);
  destination = titan_winfs_path(L, 1, &error);
  if (destination == NULL)
    return titan_winfs_error(L, "reserve sibling", error);
  length = wcslen(destination);
  for (i = 0; i < length; ++i) {
    if (destination[i] == L'/' || destination[i] == L'\\')
      prefix_length = i + 1;
  }
  if (prefix_length == 0 && length >= 2 && destination[1] == L':' &&
      ((destination[0] >= L'A' && destination[0] <= L'Z') ||
       (destination[0] >= L'a' && destination[0] <= L'z')))
    prefix_length = 2;
  if (prefix_length == length)
    return titan_winfs_invalid(L, "reserve sibling",
                               "destination must include a filename", ERROR_INVALID_NAME);
  return titan_winfs_reserve(L, destination, prefix_length, directory,
                             "reserve sibling");
}

static int titan_winfs_replace(lua_State *L) {
  DWORD error;
  WCHAR *from = titan_winfs_path(L, 1, &error);
  WCHAR *to;
  if (from == NULL)
    return titan_winfs_error(L, "rename source", error);
  to = titan_winfs_path(L, 2, &error);
  if (to == NULL)
    return titan_winfs_error(L, "rename destination", error);
  /* One same-volume namespace operation. In particular, no COPY_ALLOWED,
  ** explicit destination deletion, retry-through-copy, or reboot deferral.
  ** Durability across power loss is outside this publication contract.
  */
  if (!MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING))
    return titan_winfs_error(L, "rename", GetLastError());
  lua_pushboolean(L, 1);
  return 1;
}

#endif
