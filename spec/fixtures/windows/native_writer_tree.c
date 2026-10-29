#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

/* A real compiler wrapper whose delayed writer uses ordinary CreateProcess,
 * not luv. Its child therefore escapes a silent-breakaway-only luv job. */
static int error(const char *operation) {
  fprintf(stderr, "%s: Windows error %lu\n", operation,
          (unsigned long)GetLastError());
  return 90;
}

static int process_status(DWORD pid, DWORD timeout, int stop) {
  HANDLE process = OpenProcess(SYNCHRONIZE | (stop ? PROCESS_TERMINATE : 0),
                               FALSE, pid);
  DWORD result;
  if (process == NULL)
    return GetLastError() == ERROR_INVALID_PARAMETER ? 0 : error("OpenProcess");
  if (stop && !TerminateProcess(process, 91)) {
    CloseHandle(process);
    return error("TerminateProcess");
  }
  result = WaitForSingleObject(process, timeout);
  CloseHandle(process);
  return result == WAIT_OBJECT_0 ? 0 : result == WAIT_TIMEOUT ? 1 : error("wait");
}

static int writer(void) {
  const wchar_t *ready = _wgetenv(L"TITAN_TREE_READY");
  const wchar_t *release = _wgetenv(L"TITAN_TREE_RELEASE");
  const wchar_t *finished = _wgetenv(L"TITAN_TREE_FINISHED");
  const wchar_t *output = _wgetenv(L"TITAN_TREE_OUTPUT");
  wchar_t temporary[32768];
  char utf8[32768];
  FILE *file;
  DWORD start = GetTickCount();
  if (!ready || !release || !finished || !output) return 92;
  if (swprintf(temporary, 32768, L"%ls.tmp", ready) < 0) return 93;
  if (!WideCharToMultiByte(CP_UTF8, 0, output, -1, utf8, sizeof utf8,
                           NULL, NULL)) return error("encode target");
  file = _wfopen(temporary, L"wb");
  if (!file) return 94;
  fprintf(file, "%lu\n%s\n", (unsigned long)GetCurrentProcessId(), utf8);
  if (fclose(file) != 0) return 95;
  if (!MoveFileExW(temporary, ready, MOVEFILE_REPLACE_EXISTING))
    return error("publish writer readiness");
  while (GetFileAttributesW(release) == INVALID_FILE_ATTRIBUTES) {
    if (GetTickCount() - start > 120000) return 96;
    Sleep(10);
  }
  file = _wfopen(output, L"wb");
  if (!file) return 97;
  fputs("stale descendant overwrote the native output\n", file);
  if (fclose(file) != 0) return 98;
  file = _wfopen(finished, L"wb");
  if (!file) return 99;
  fputs("wrote\n", file);
  return fclose(file) == 0 ? 0 : 100;
}

static int launch(wchar_t *command) {
  STARTUPINFOW startup;
  PROCESS_INFORMATION child;
  DWORD code;
  ZeroMemory(&startup, sizeof startup);
  startup.cb = sizeof startup;
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  ZeroMemory(&child, sizeof child);
  if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL,
                      &startup, &child)) return error("CreateProcessW");
  CloseHandle(child.hThread);
  if (WaitForSingleObject(child.hProcess, INFINITE) != WAIT_OBJECT_0) {
    CloseHandle(child.hProcess);
    return error("wait for compiler child");
  }
  if (!GetExitCodeProcess(child.hProcess, &code)) {
    CloseHandle(child.hProcess);
    return error("compiler child exit status");
  }
  CloseHandle(child.hProcess);
  return (int)code;
}

int wmain(int argc, wchar_t **argv) {
  const wchar_t *match = _wgetenv(L"TITAN_TREE_MATCH");
  const wchar_t *real = _wgetenv(L"TITAN_TREE_REAL_CC");
  const wchar_t *tail = GetCommandLineW();
  const wchar_t *output = NULL;
  wchar_t command[32768], self[32768];
  int selected = 0;
  if (argc == 2 && wcscmp(argv[1], L"--writer") == 0) return writer();
  if (argc == 4 && wcscmp(argv[1], L"--wait-dead") == 0)
    return process_status(wcstoul(argv[2], NULL, 10),
                          wcstoul(argv[3], NULL, 10), 0);
  if (argc == 3 && wcscmp(argv[1], L"--stop") == 0)
    return process_status(wcstoul(argv[2], NULL, 10), 10000, 1);
  for (int index = 1; index < argc; ++index) {
    const wchar_t *basename = argv[index];
    for (const wchar_t *at = basename; *at; ++at)
      if (*at == '/' || *at == '\\') basename = at + 1;
    if (match && wcscmp(basename, match) == 0) selected = 1;
    if (wcscmp(argv[index], L"-o") == 0 && index + 1 < argc)
      output = argv[index + 1];
  }
  if (selected && output) {
    DWORD length = GetModuleFileNameW(NULL, self, 32768);
    if (length == 0 || length >= 32768) return error("wrapper filename");
    if (!SetEnvironmentVariableW(L"TITAN_TREE_OUTPUT", output))
      return error("writer output environment");
    if (swprintf(command, 32768, L"\"%ls\" --writer", self) < 0) return 101;
    return launch(command);
  }
  if (!real) return 102;
  /* Preserve luv's complete CRT-quoted argument tail when forwarding to the
   * configured real compiler prefix. No shell or second argv parser. */
  if (*tail == '"') {
    ++tail;
    while (*tail && *tail != '"') ++tail;
    if (*tail) ++tail;
  } else {
    while (*tail && *tail != ' ' && *tail != '\t') ++tail;
  }
  while (*tail == ' ' || *tail == '\t') ++tail;
  if (swprintf(command, 32768, L"%ls %ls", real, tail) < 0) return 103;
  return launch(command);
}
