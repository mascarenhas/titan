/* Windows process oracle: observe UTF-16 argv/environment/cwd independently of
 * Titan, then emit the existing length-prefixed UTF-8 fixture protocol. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static char *utf8(const wchar_t *wide) {
  int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                                  NULL, 0, NULL, NULL);
  char *bytes;
  if (length == 0) return NULL;
  bytes = (char *)malloc((size_t)length);
  if (bytes == NULL) return NULL;
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, bytes,
                          length, NULL, NULL) == 0) {
    free(bytes); return NULL;
  }
  return bytes;
}

static char *environment(const wchar_t *name, int *present, int *ok) {
  DWORD length, actual, error;
  wchar_t *wide;
  char *bytes;
  *present = 0; *ok = 0;
  SetLastError(ERROR_SUCCESS);
  length = GetEnvironmentVariableW(name, NULL, 0);
  if (length == 0) {
    error = GetLastError();
    if (error == ERROR_ENVVAR_NOT_FOUND) { *ok = 1; return NULL; }
    if (error != ERROR_SUCCESS) return NULL;
    bytes = utf8(L""); *present = 1; *ok = bytes != NULL; return bytes;
  }
  wide = (wchar_t *)malloc((size_t)length * sizeof(wchar_t));
  if (wide == NULL) return NULL;
  SetLastError(ERROR_SUCCESS);
  actual = GetEnvironmentVariableW(name, wide, length);
  if ((actual == 0 && GetLastError() != ERROR_SUCCESS) || actual >= length) {
    free(wide); return NULL;
  }
  bytes = utf8(wide); free(wide);
  *present = 1; *ok = bytes != NULL; return bytes;
}

static int write_all(FILE *stream, const void *data, size_t length) {
  const unsigned char *cursor = (const unsigned char *)data;
  while (length > 0) {
    size_t written = fwrite(cursor, 1, length, stream);
    if (written == 0) return 1;
    cursor += written; length -= written;
  }
  return 0;
}

static int write_field(const char *label, const char *value) {
  size_t length = strlen(value);
  return printf("%s:%zu:", label, length) < 0 ||
         write_all(stdout, value, length) != 0 || fputc('\n', stdout) == EOF;
}

static int argv_env_cwd(int argc, char **argv, wchar_t **wide_argv) {
  DWORD capacity, length;
  wchar_t *wide;
  char *cwd, *value;
  int index, present, ok, result;
  if (argc < 3) return 2;
  capacity = GetCurrentDirectoryW(0, NULL);
  if (capacity == 0) return 3;
  wide = (wchar_t *)malloc((size_t)capacity * sizeof(wchar_t));
  if (wide == NULL) return 3;
  length = GetCurrentDirectoryW(capacity, wide);
  if (length == 0 || length >= capacity) { free(wide); return 3; }
  cwd = utf8(wide); free(wide);
  if (cwd == NULL) return 3;
  value = environment(wide_argv[2], &present, &ok);
  if (!ok) { free(cwd); return 3; }
  result = write_field("cwd", cwd) || write_field("env", present ? value : "") ||
           write_field("argv0", argv[0]);
  free(cwd); free(value);
  if (result) return 4;
  for (index = 3; index < argc; index++) if (write_field("arg", argv[index])) return 5;
  return fflush(stdout) == 0 ? 0 : 6;
}

static int run(int argc, char **argv, wchar_t **wide_argv) {
  int index;
  if (argc < 2) return 2;
  if (strcmp(argv[1], "argv-env-cwd") == 0) return argv_env_cwd(argc, argv, wide_argv);
  if (strcmp(argv[1], "environment") == 0) {
    for (index = 2; index < argc; index++) {
      int present, ok, result;
      char *value = environment(wide_argv[index], &present, &ok);
      if (!ok) return 3;
      result = present ? write_field("env", value) : fputs("absent\n", stdout) == EOF;
      free(value);
      if (result) return 4;
    }
    return fflush(stdout) == 0 ? 0 : 5;
  }
  if (strcmp(argv[1], "echo") == 0) {
    unsigned char buffer[4096]; size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), stdin)) > 0)
      if (write_all(stdout, buffer, count)) return 1;
    return ferror(stdin) || fflush(stdout) != 0 ? 2 : 0;
  }
  if (strcmp(argv[1], "echo-count") == 0 && argc == 3) {
    long remaining = strtol(argv[2], NULL, 10);
    if (remaining < 0) return 2;
    while (remaining-- > 0) {
      int byte = fgetc(stdin);
      if (byte == EOF || fputc(byte, stdout) == EOF) return 1;
    }
    return fflush(stdout) == 0 ? 0 : 2;
  }
  if (strcmp(argv[1], "dual") == 0 && argc == 3) {
    long count = strtol(argv[2], NULL, 10), i;
    for (i = 0; i < count; i++)
      if (fputc('O', stdout) == EOF || fputc('E', stderr) == EOF) return 1;
    return fflush(stdout) == 0 && fflush(stderr) == 0 ? 0 : 2;
  }
  if (strcmp(argv[1], "exit") == 0 && argc == 3) return (int)strtol(argv[2], NULL, 10);
  if (strcmp(argv[1], "ready-wait") == 0) {
    if (fputs("READY\n", stdout) == EOF || fflush(stdout) != 0) return 3;
    Sleep(INFINITE);
  }
  return 2;
}

int wmain(int argc, wchar_t **wide_argv) {
  char **argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
  int index, result;
  if (argv == NULL) return 3;
  if (_setmode(_fileno(stdin), _O_BINARY) == -1 ||
      _setmode(_fileno(stdout), _O_BINARY) == -1 ||
      _setmode(_fileno(stderr), _O_BINARY) == -1) { free(argv); return 3; }
  for (index = 0; index < argc; index++) {
    argv[index] = utf8(wide_argv[index]);
    if (argv[index] == NULL) {
      while (index > 0) free(argv[--index]);
      free(argv); return 3;
    }
  }
  result = run(argc, argv, wide_argv);
  for (index = 0; index < argc; index++) free(argv[index]);
  free(argv); return result;
}
