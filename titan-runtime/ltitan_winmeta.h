/* Private Windows compiler metadata and existing-path resolution. */
#ifndef TITAN_LTITAN_WINMETA_H
#define TITAN_LTITAN_WINMETA_H

#include "ltitan_winfs.h"

#define TITAN_WINMETA_PATH_CAPACITY TITAN_WINFS_PATH_CAPACITY
#define TITAN_WINMETA_HANDLE_MT "titan.compiler.winfs.metadata-handle"

typedef struct titan_winmeta_handle {
  HANDLE handle;
} titan_winmeta_handle;

static int titan_winmeta_close_guard(lua_State *L) {
  titan_winmeta_handle *owner =
      (titan_winmeta_handle *)luaL_testudata(L, 1, TITAN_WINMETA_HANDLE_MT);
  if (owner != NULL && owner->handle != INVALID_HANDLE_VALUE &&
      CloseHandle(owner->handle))
    owner->handle = INVALID_HANDLE_VALUE;
  return 0;
}

/* Allocate and register the owner BEFORE opening any OS handle. All ordinary
** queries close before constructing Lua results; this guard covers unexpected
** CloseHandle failures and allocation errors while reporting those failures.
** It never unlinks or mutates the queried filesystem object.
*/
static titan_winmeta_handle *titan_winmeta_new_guard(lua_State *L) {
  titan_winmeta_handle *owner =
      (titan_winmeta_handle *)lua_newuserdatauv(L, sizeof(*owner), 0);
  owner->handle = INVALID_HANDLE_VALUE;
  if (luaL_newmetatable(L, TITAN_WINMETA_HANDLE_MT)) {
    lua_pushcfunction(L, titan_winmeta_close_guard);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, titan_winmeta_close_guard);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_toclose(L, -1);
  return owner;
}

static DWORD titan_winmeta_close(titan_winmeta_handle *owner) {
  if (owner->handle == INVALID_HANDLE_VALUE) return ERROR_SUCCESS;
  if (!CloseHandle(owner->handle)) return GetLastError();
  owner->handle = INVALID_HANDLE_VALUE;
  return ERROR_SUCCESS;
}

static void titan_winmeta_hex64(char *result, ULONGLONG value) {
  static const char hex[] = "0123456789abcdef";
  int i;
  for (i = 0; i < 16; ++i)
    result[i] = hex[(value >> (4 * (15 - i))) & 15];
  result[16] = '\0';
}

static int titan_winmeta_guid_root(const WCHAR *path, DWORD length) {
  size_t i;
  if (length < 49 || wcsncmp(path, L"\\\\?\\Volume{", 11) != 0 ||
      path[47] != L'}' || path[48] != L'\\')
    return 0;
  for (i = 0; i < 36; ++i) {
    WCHAR c = path[11 + i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != L'-') return 0;
    } else if (!((c >= L'0' && c <= L'9') ||
                 (c >= L'a' && c <= L'f') ||
                 (c >= L'A' && c <= L'F'))) {
      return 0;
    }
  }
  return 1;
}

/* Identity is exclusively handle-reported data. FileIdInfo is authoritative
** whenever available, including on ReFS. The approved fallback is deliberately
** narrower than generic legacy Win32 identity: only unsupported query errors
** on the positively identified VirtIO-FS filesystem may use the real GUID root
** and the full legacy 64-bit file index. Never use its zero volume serial.
*/
static DWORD titan_winmeta_identity(HANDLE handle, WCHAR *scratch,
                                   char *device, char *inode,
                                   const char **operation) {
  FILE_ID_INFO id;
  DWORD preferred_error;
  size_t i;
  static const char hex[] = "0123456789abcdef";

  *operation = "stat FileIdInfo";
  if (GetFileInformationByHandleEx(handle, FileIdInfo, &id, sizeof(id))) {
    strcpy(device, "win32-volume:");
    titan_winmeta_hex64(device + strlen("win32-volume:"), id.VolumeSerialNumber);
    strcpy(inode, "win32-file:");
    for (i = 0; i < sizeof(id.FileId.Identifier); ++i) {
      unsigned char byte = id.FileId.Identifier[i];
      inode[strlen("win32-file:") + 2 * i] = hex[byte >> 4];
      inode[strlen("win32-file:") + 2 * i + 1] = hex[byte & 15];
    }
    inode[strlen("win32-file:") + 2 * sizeof(id.FileId.Identifier)] = '\0';
    return ERROR_SUCCESS;
  }
  preferred_error = GetLastError();
  if (preferred_error != ERROR_INVALID_FUNCTION &&
      preferred_error != ERROR_NOT_SUPPORTED &&
      preferred_error != ERROR_INVALID_PARAMETER)
    return preferred_error;
  {
    WCHAR filesystem[256];
    BY_HANDLE_FILE_INFORMATION legacy;
    DWORD length;
    ULONGLONG index;
    *operation = "stat filesystem identity";
    if (!GetVolumeInformationByHandleW(handle, NULL, 0, NULL, NULL, NULL,
                                      filesystem, 256))
      return GetLastError();
    if (wcscmp(filesystem, L"VirtIO-FS") != 0) {
      *operation = "stat FileIdInfo (legacy fallback requires VirtIO-FS)";
      return preferred_error;
    }
    *operation = "stat VirtIO-FS file index";
    if (!GetFileInformationByHandle(handle, &legacy)) return GetLastError();
    *operation = "stat VirtIO-FS volume GUID";
    length = GetFinalPathNameByHandleW(
        handle, scratch, TITAN_WINMETA_PATH_CAPACITY,
        FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
    if (length == 0) return GetLastError();
    if (length >= TITAN_WINMETA_PATH_CAPACITY)
      return ERROR_FILENAME_EXCED_RANGE;
    if (!titan_winmeta_guid_root(scratch, length)) return ERROR_INVALID_DATA;
    strcpy(device, "win32-volume-guid:");
    /* The validated GUID-root grammar consists entirely of ASCII. Preserve
    ** the exact root reported by the handle; no pathname-derived identifier.
    */
    for (i = 0; i < 49; ++i)
      device[strlen("win32-volume-guid:") + i] = (char)scratch[i];
    device[strlen("win32-volume-guid:") + 49] = '\0';
    index = ((ULONGLONG)legacy.nFileIndexHigh << 32) | legacy.nFileIndexLow;
    strcpy(inode, "win32-legacy-file:");
    titan_winmeta_hex64(inode + strlen("win32-legacy-file:"), index);
  }
  return ERROR_SUCCESS;
}

/* An opened reparse handle has deliberate semantics only for ordinary Windows
** symlinks and mount-point/junction tags. Other tags are unsupported, not
** silently reported as ordinary files or links. Successful following normally
** leaves no name-surrogate tag on the resulting handle.
*/
static DWORD titan_winmeta_kind(HANDLE handle, int follow, const char **kind,
                               lua_Integer *mode, char *operation,
                               size_t operation_capacity) {
  FILE_ATTRIBUTE_TAG_INFO tag;
  snprintf(operation, operation_capacity, "stat reparse metadata");
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, sizeof(tag)))
    return GetLastError();
  if (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
    if (tag.ReparseTag != IO_REPARSE_TAG_SYMLINK &&
        tag.ReparseTag != IO_REPARSE_TAG_MOUNT_POINT) {
      snprintf(operation, operation_capacity,
               "stat unsupported reparse tag 0x%08lx",
               (unsigned long)tag.ReparseTag);
      return ERROR_NOT_SUPPORTED;
    }
    if (follow) {
      snprintf(operation, operation_capacity, "stat unresolved reparse point");
      return ERROR_CANT_RESOLVE_FILENAME;
    }
    *kind = "symlink";
    *mode = 0xa000;
  } else if (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
    *kind = "directory";
    *mode = 0x4000;
  } else {
    *kind = "file";
    *mode = 0x8000;
  }
  /* Deliberately no synthetic rwx bits: file attributes are not POSIX ACLs. */
  return ERROR_SUCCESS;
}

static int titan_winfs_stat(lua_State *L) {
  DWORD error;
  DWORD close_error;
  WCHAR *path;
  WCHAR *scratch;
  titan_winmeta_handle *owner;
  int follow;
  FILE_BASIC_INFO basic;
  FILE_STANDARD_INFO standard;
  const char *kind = NULL;
  const char *operation = "stat open";
  char kind_operation[128];
  char device[96];
  char inode[64];
  lua_Integer mode = 0;
  LONGLONG seconds;
  LONGLONG nanoseconds;

  if (lua_type(L, 2) != LUA_TBOOLEAN)
    return titan_winfs_invalid(L, "stat", "follow must be a boolean",
                              ERROR_INVALID_PARAMETER);
  follow = lua_toboolean(L, 2);
  path = titan_winfs_path(L, 1, &error);
  if (path == NULL) return titan_winfs_error(L, "stat path", error);
  scratch = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINMETA_PATH_CAPACITY * sizeof(WCHAR), 0);
  owner = titan_winmeta_new_guard(L);
  owner->handle = CreateFileW(
      path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT), NULL);
  if (owner->handle == INVALID_HANDLE_VALUE)
    return titan_winfs_error(L, operation, GetLastError());

  error = titan_winmeta_kind(owner->handle, follow, &kind, &mode,
                            kind_operation, sizeof(kind_operation));
  if (error != ERROR_SUCCESS) {
    operation = kind_operation;
    goto failed;
  }
  operation = "stat basic metadata";
  if (!GetFileInformationByHandleEx(owner->handle, FileBasicInfo, &basic, sizeof(basic))) {
    error = GetLastError();
    goto failed;
  }
  operation = "stat standard metadata";
  if (!GetFileInformationByHandleEx(owner->handle, FileStandardInfo,
                                    &standard, sizeof(standard))) {
    error = GetLastError();
    goto failed;
  }
  if (standard.EndOfFile.QuadPart < 0 || basic.LastWriteTime.QuadPart < 0) {
    error = ERROR_INVALID_DATA;
    operation = "stat negative size or FILETIME";
    goto failed;
  }
  seconds = basic.LastWriteTime.QuadPart / 10000000LL - 11644473600LL;
  nanoseconds = (basic.LastWriteTime.QuadPart % 10000000LL) * 100LL;
  if (standard.EndOfFile.QuadPart > LUA_MAXINTEGER ||
      seconds > LUA_MAXINTEGER || seconds < LUA_MININTEGER ||
      nanoseconds > LUA_MAXINTEGER) {
    error = ERROR_ARITHMETIC_OVERFLOW;
    operation = "stat Lua integer range";
    goto failed;
  }
  error = titan_winmeta_identity(owner->handle, scratch, device, inode, &operation);
  if (error != ERROR_SUCCESS) goto failed;
  error = titan_winmeta_close(owner);
  if (error != ERROR_SUCCESS)
    return titan_winfs_error(L, "stat close", error);

  /* No live OS handle remains while allocating the public result. All seven
  ** fields preserve the compiler-I/O shape; identity components are opaque.
  */
  lua_createtable(L, 0, 7);
  lua_pushstring(L, kind);
  lua_setfield(L, -2, "kind");
  lua_pushinteger(L, (lua_Integer)standard.EndOfFile.QuadPart);
  lua_setfield(L, -2, "size");
  lua_pushinteger(L, mode);
  lua_setfield(L, -2, "mode");
  lua_pushstring(L, device);
  lua_setfield(L, -2, "device");
  lua_pushstring(L, inode);
  lua_setfield(L, -2, "inode");
  lua_pushinteger(L, (lua_Integer)seconds);
  lua_setfield(L, -2, "modified_seconds");
  lua_pushinteger(L, (lua_Integer)nanoseconds);
  lua_setfield(L, -2, "modified_nanoseconds");
  return 1;

failed:
  close_error = titan_winmeta_close(owner);
  /* Retain the originating query error. If closing failed too, the armed Lua
  ** owner retries on return/unwinding and then at finalization.
  */
  (void)close_error;
  return titan_winfs_error(L, operation, error);
}

static int titan_winfs_abspath(lua_State *L) {
  DWORD error, length;
  WCHAR *path = titan_winfs_path(L, 1, &error);
  WCHAR *result;
  if (path == NULL) return titan_winfs_error(L, "absolute path", error);
  result = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINMETA_PATH_CAPACITY * sizeof(WCHAR), 0);
  length = GetFullPathNameW(path, TITAN_WINMETA_PATH_CAPACITY, result, NULL);
  if (length == 0) return titan_winfs_error(L, "absolute path", GetLastError());
  if (length >= TITAN_WINMETA_PATH_CAPACITY)
    return titan_winfs_error(L, "absolute path", ERROR_FILENAME_EXCED_RANGE);
  if (!titan_winfs_push_path(L, result, &error))
    return titan_winfs_error(L, "absolute path UTF-8", error);
  return 1;
}

static int titan_winfs_realpath(lua_State *L) {
  DWORD error;
  DWORD length;
  WCHAR *path = titan_winfs_path(L, 1, &error);
  WCHAR *result;
  titan_winmeta_handle *owner;
  const char *kind;
  lua_Integer mode;
  char operation[128];
  if (path == NULL) return titan_winfs_error(L, "realpath path", error);
  result = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINMETA_PATH_CAPACITY * sizeof(WCHAR), 0);
  owner = titan_winmeta_new_guard(L);
  owner->handle = CreateFileW(
      path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (owner->handle == INVALID_HANDLE_VALUE)
    return titan_winfs_error(L, "realpath open", GetLastError());
  error = titan_winmeta_kind(owner->handle, 1, &kind, &mode,
                            operation, sizeof(operation));
  if (error != ERROR_SUCCESS) {
    titan_winmeta_close(owner);
    return titan_winfs_error(L, operation, error);
  }
  length = GetFinalPathNameByHandleW(
      owner->handle, result, TITAN_WINMETA_PATH_CAPACITY,
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  error = length == 0 ? GetLastError() :
      (length >= TITAN_WINMETA_PATH_CAPACITY ? ERROR_FILENAME_EXCED_RANGE : ERROR_SUCCESS);
  if (error != ERROR_SUCCESS) {
    titan_winmeta_close(owner);
    return titan_winfs_error(L, "realpath final path", error);
  }
  error = titan_winmeta_close(owner);
  if (error != ERROR_SUCCESS)
    return titan_winfs_error(L, "realpath close", error);
  /* This is exactly the OS-reported resolved spelling, including its extended
  ** prefix. No prefix is synthesized and no path identity is inferred here.
  */
  if (!titan_winfs_push_path(L, result, &error))
    return titan_winfs_error(L, "realpath UTF-8", error);
  return 1;
}

#endif
