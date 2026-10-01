/* Private Windows compiler executable lookup; no process is launched here. */
#ifndef TITAN_LTITAN_WINTOOL_H
#define TITAN_LTITAN_WINTOOL_H

#include "ltitan_winfs.h"

static int titan_winfs_resolve_executable(lua_State *L) {
  DWORD error, length, attributes, binary_type;
  WCHAR *input = titan_winfs_path(L, 1, &error);
  WCHAR *candidate, *absolute;
  const WCHAR *leaf, *extension;
  size_t i, count;
  int explicit_path = 0;
  if (input == NULL) return titan_winfs_error(L, "executable path", error);
  count = wcslen(input);
  candidate = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINFS_PATH_CAPACITY * sizeof(WCHAR), 0);
  absolute = (WCHAR *)lua_newuserdatauv(
      L, TITAN_WINFS_PATH_CAPACITY * sizeof(WCHAR), 0);
  leaf = input;
  for (i = 0; i < count; ++i) {
    if (input[i] == L'/' || input[i] == L'\\') {
      explicit_path = 1;
      leaf = input + i + 1;
    } else if (input[i] == L':') {
      explicit_path = 1;
    }
  }
  extension = wcsrchr(leaf, L'.');
  if (extension != NULL && _wcsicmp(extension, L".exe") != 0 &&
      _wcsicmp(extension, L".com") != 0)
    return titan_winfs_invalid(L, "executable path",
        "only native .exe/.com tools are supported", ERROR_BAD_EXE_FORMAT);
  if (count + (extension == NULL ? 4 : 0) >= TITAN_WINFS_PATH_CAPACITY)
    return titan_winfs_error(L, "executable path", ERROR_FILENAME_EXCED_RANGE);
  wcscpy(candidate, input);
  if (extension == NULL) wcscat(candidate, L".exe");
  if (explicit_path) {
    length = GetFullPathNameW(candidate, TITAN_WINFS_PATH_CAPACITY, absolute, NULL);
  } else {
    /* Use the documented SearchPathW order, including the process's existing
    ** SafeProcessSearchMode. Do not alter it or emulate cmd's PATHEXT/batch
    ** search. The caller receives this exact selected file before rendering.
    */
    length = SearchPathW(NULL, candidate, NULL, TITAN_WINFS_PATH_CAPACITY,
                         absolute, NULL);
  }
  if (length == 0) return titan_winfs_error(L, "resolve executable", GetLastError());
  if (length >= TITAN_WINFS_PATH_CAPACITY)
    return titan_winfs_error(L, "resolve executable", ERROR_FILENAME_EXCED_RANGE);
  /* SearchPathW can preserve a relative search-path entry. Make the selected
  ** location absolute without changing its component spelling or case.
  */
  length = GetFullPathNameW(absolute, TITAN_WINFS_PATH_CAPACITY, candidate, NULL);
  if (length == 0) return titan_winfs_error(L, "absolute executable", GetLastError());
  if (length >= TITAN_WINFS_PATH_CAPACITY)
    return titan_winfs_error(L, "absolute executable", ERROR_FILENAME_EXCED_RANGE);
  attributes = GetFileAttributesW(candidate);
  if (attributes == INVALID_FILE_ATTRIBUTES)
    return titan_winfs_error(L, "executable attributes", GetLastError());
  if (attributes & FILE_ATTRIBUTE_DIRECTORY)
    return titan_winfs_invalid(L, "executable path", "path is a directory",
                               ERROR_BAD_EXE_FORMAT);
  if (!GetBinaryTypeW(candidate, &binary_type))
    return titan_winfs_error(L, "executable image", GetLastError());
  if (binary_type != SCS_32BIT_BINARY && binary_type != SCS_64BIT_BINARY)
    return titan_winfs_invalid(L, "executable image",
        "tool is not a native Windows executable", ERROR_BAD_EXE_FORMAT);
  /* This is preflight, not an atomic launch guarantee. The file and access
  ** rights can still change before the shell opens it; preserve that status.
  */
  if (!titan_winfs_push_path(L, candidate, &error))
    return titan_winfs_error(L, "executable UTF-8", error);
  return 1;
}

#endif
