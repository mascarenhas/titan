/* Private Windows generated-C worker transport. Completion callbacks never
** enter Lua: they only post request indices to the owning batch's port.
*/
#ifndef TITAN_LTITAN_WINPROCESS_H
#define TITAN_LTITAN_WINPROCESS_H

#include "ltitan_winfs.h"
#include <stdlib.h>

#define TITAN_WINPROCESS_MT "titan.compiler.winprocess.batch"

typedef struct titan_winprocess_batch titan_winprocess_batch;
typedef struct titan_winprocess_child {
  struct titan_winprocess_child *next;
  titan_winprocess_batch *batch;
  HANDLE process;
  PTP_WAIT wait;
  DWORD index;
} titan_winprocess_child;

struct titan_winprocess_batch {
  HANDLE port, job;
  titan_winprocess_child *children;
  volatile LONG completion_error;
};

static VOID CALLBACK titan_winprocess_completed(
    PTP_CALLBACK_INSTANCE instance, PVOID context, PTP_WAIT wait,
    TP_WAIT_RESULT result) {
  titan_winprocess_child *child = (titan_winprocess_child *)context;
  (void)instance; (void)wait; (void)result;
  if (!PostQueuedCompletionStatus(child->batch->port, child->index, 0, NULL))
    InterlockedCompareExchange(&child->batch->completion_error,
                               (LONG)GetLastError(), 0);
}

static void titan_winprocess_release(titan_winprocess_child *child) {
  if (child->wait != NULL) {
    SetThreadpoolWait(child->wait, NULL, NULL);
    WaitForThreadpoolWaitCallbacks(child->wait, TRUE);
    CloseThreadpoolWait(child->wait);
  }
  CloseHandle(child->process);
  free(child);
}

static DWORD titan_winprocess_close_batch(titan_winprocess_batch *batch) {
  DWORD error = ERROR_SUCCESS;
  titan_winprocess_child *child;
  if (batch->job != NULL) {
    if (!TerminateJobObject(batch->job, ERROR_PROCESS_ABORTED))
      error = GetLastError();
  }
  while ((child = batch->children) != NULL) {
    batch->children = child->next;
    if (WaitForSingleObject(child->process, INFINITE) == WAIT_FAILED &&
        error == ERROR_SUCCESS) error = GetLastError();
    titan_winprocess_release(child);
  }
  if (batch->job != NULL) {
    if (error == ERROR_SUCCESS) {
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
      /* Termination is asynchronous. Release our process handles and waits
      ** first, then await descendants before replaying or removing their logs.
      */
      for (;;) {
        if (!QueryInformationJobObject(batch->job, JobObjectBasicAccountingInformation,
                                       &accounting, sizeof(accounting), NULL)) {
          error = GetLastError();
          break;
        }
        if (accounting.ActiveProcesses == 0) break;
        Sleep(1);
      }
    }
    CloseHandle(batch->job);
    batch->job = NULL;
  }
  /* Release callback contexts and drain callbacks before closing their port. */
  if (batch->port != NULL) {
    CloseHandle(batch->port);
    batch->port = NULL;
  }
  return error;
}

static int titan_winprocess_gc(lua_State *L) {
  titan_winprocess_batch *batch = (titan_winprocess_batch *)
      luaL_testudata(L, 1, TITAN_WINPROCESS_MT);
  if (batch != NULL) titan_winprocess_close_batch(batch);
  return 0;
}

static int titan_winprocess_new(lua_State *L) {
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  DWORD error;
  titan_winprocess_batch *batch;
  if (luaL_newmetatable(L, TITAN_WINPROCESS_MT)) {
    lua_pushcfunction(L, titan_winprocess_gc);
    lua_setfield(L, -2, "__gc");
  }
  batch = (titan_winprocess_batch *)lua_newuserdatauv(L, sizeof(*batch), 0);
  memset(batch, 0, sizeof(*batch));
  lua_pushvalue(L, -2);
  lua_setmetatable(L, -2);
  batch->port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
  if (batch->port == NULL) goto failed;
  batch->job = CreateJobObjectW(NULL, NULL);
  if (batch->job == NULL) goto failed;
  memset(&limits, 0, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(batch->job, JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) goto failed;
  return 1;
failed:
  error = GetLastError();
  titan_winprocess_close_batch(batch);
  return titan_winfs_error(L, "create compiler batch", error);
}

/* Preserve the parent's sorted Unicode environment, including per-drive cwd
** entries, while setting only the compiler's existing deterministic locale.
*/
static WCHAR *titan_winprocess_environment(DWORD *error) {
  WCHAR *original = GetEnvironmentStringsW(), *cursor, *copy, *output;
  const WCHAR *additions[] = { L"LANG=C", L"LC_ALL=C" };
  size_t units = 1, next = 0, length;
  if (original == NULL) { *error = GetLastError(); return NULL; }
  for (cursor = original; *cursor != L'\0'; cursor += wcslen(cursor) + 1)
    units += wcslen(cursor) + 1;
  units += 7 + 9;
  copy = (WCHAR *)malloc(units * sizeof(WCHAR));
  if (copy == NULL) {
    FreeEnvironmentStringsW(original);
    *error = ERROR_NOT_ENOUGH_MEMORY;
    return NULL;
  }
  output = copy;
  for (cursor = original; *cursor != L'\0'; cursor += length + 1) {
    length = wcslen(cursor);
    if (_wcsnicmp(cursor, L"LANG=", 5) == 0 ||
        _wcsnicmp(cursor, L"LC_ALL=", 7) == 0) continue;
    while (next < 2 && CompareStringOrdinal(
        additions[next], next == 0 ? 4 : 6, cursor,
        (int)(wcschr(cursor + (*cursor == L'=' ? 1 : 0), L'=') - cursor),
        TRUE) == CSTR_LESS_THAN) {
      size_t added = wcslen(additions[next]) + 1;
      memcpy(output, additions[next++], added * sizeof(WCHAR));
      output += added;
    }
    memcpy(output, cursor, (length + 1) * sizeof(WCHAR));
    output += length + 1;
  }
  while (next < 2) {
    size_t added = wcslen(additions[next]) + 1;
    memcpy(output, additions[next++], added * sizeof(WCHAR));
    output += added;
  }
  *output = L'\0';
  FreeEnvironmentStringsW(original);
  return copy;
}

static int titan_winprocess_spawn(lua_State *L) {
  titan_winprocess_batch *batch = (titan_winprocess_batch *)
      luaL_checkudata(L, 1, TITAN_WINPROCESS_MT);
  lua_Integer index = luaL_checkinteger(L, 2);
  DWORD error = ERROR_SUCCESS;
  WCHAR *executable = titan_winfs_path(L, 3, &error);
  WCHAR *command, *stdout_path, *stderr_path, *environment = NULL;
  HANDLE handles[3] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE,
                        INVALID_HANDLE_VALUE };
  SECURITY_ATTRIBUTES security = { sizeof(security), NULL, TRUE };
  STARTUPINFOEXW startup;
  PROCESS_INFORMATION process;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  SIZE_T attribute_size = 0;
  titan_winprocess_child *child = NULL, *existing;
  int created = 0, attributes_initialized = 0;
  if (executable == NULL) return titan_winfs_error(L, "compiler executable", error);
  command = titan_winfs_path(L, 4, &error);
  if (command == NULL) return titan_winfs_error(L, "compiler command", error);
  stdout_path = titan_winfs_path(L, 5, &error);
  if (stdout_path == NULL) return titan_winfs_error(L, "compiler stdout", error);
  stderr_path = titan_winfs_path(L, 6, &error);
  if (stderr_path == NULL) return titan_winfs_error(L, "compiler stderr", error);
  if (batch->port == NULL || index < 1 || (lua_Unsigned)index > MAXDWORD)
    return titan_winfs_invalid(L, "compiler batch", "closed batch or invalid index",
                               ERROR_INVALID_PARAMETER);
  if (wcslen(command) >= 32767)
    return titan_winfs_error(L, "compiler command", ERROR_FILENAME_EXCED_RANGE);
  for (existing = batch->children; existing != NULL; existing = existing->next)
    if (existing->index == (DWORD)index)
      return titan_winfs_invalid(L, "compiler batch", "duplicate request index",
                                 ERROR_INVALID_PARAMETER);
  /* Finish Lua argument conversion/allocation before acquiring process handles.
  ** A started child is batch-owned before any subsequent Lua allocation.
  */
  memset(&startup, 0, sizeof(startup));
  memset(&process, 0, sizeof(process));
  environment = titan_winprocess_environment(&error);
  if (environment == NULL) goto failed;
  child = (titan_winprocess_child *)calloc(1, sizeof(*child));
  if (child == NULL) { error = ERROR_NOT_ENOUGH_MEMORY; goto failed; }
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attribute_size);
  if (attributes == NULL) { error = ERROR_NOT_ENOUGH_MEMORY; goto failed; }
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size))
    goto windows_failed;
  attributes_initialized = 1;
  handles[0] = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          &security, OPEN_EXISTING, 0, NULL);
  if (handles[0] == INVALID_HANDLE_VALUE) goto windows_failed;
  handles[1] = CreateFileW(stdout_path, GENERIC_WRITE, FILE_SHARE_READ,
                          &security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (handles[1] == INVALID_HANDLE_VALUE) goto windows_failed;
  handles[2] = CreateFileW(stderr_path, GENERIC_WRITE, FILE_SHARE_READ,
                          &security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (handles[2] == INVALID_HANDLE_VALUE) goto windows_failed;
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                 handles, sizeof(handles), NULL, NULL))
    goto windows_failed;
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = handles[0];
  startup.StartupInfo.hStdOutput = handles[1];
  startup.StartupInfo.hStdError = handles[2];
  startup.lpAttributeList = attributes;
  if (!CreateProcessW(executable, command, NULL, NULL, TRUE,
      CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
      environment, NULL, &startup.StartupInfo, &process)) goto windows_failed;
  created = 1;
  if (!AssignProcessToJobObject(batch->job, process.hProcess)) goto windows_failed;
  child->batch = batch;
  child->index = (DWORD)index;
  child->process = process.hProcess;
  child->wait = CreateThreadpoolWait(titan_winprocess_completed, child, NULL);
  if (child->wait == NULL) goto windows_failed;
  if (ResumeThread(process.hThread) == (DWORD)-1) goto windows_failed;
  child->next = batch->children;
  batch->children = child;
  SetThreadpoolWait(child->wait, process.hProcess, NULL);
  child = NULL;
  goto cleanup;
windows_failed:
  error = GetLastError();
failed:
  if (created) {
    TerminateProcess(process.hProcess, ERROR_PROCESS_ABORTED);
    WaitForSingleObject(process.hProcess, INFINITE);
  }
  if (child != NULL && child->wait != NULL) {
    SetThreadpoolWait(child->wait, NULL, NULL);
    WaitForThreadpoolWaitCallbacks(child->wait, TRUE);
    CloseThreadpoolWait(child->wait);
  }
  if (created) CloseHandle(process.hProcess);
  free(child);
cleanup:
  if (created) CloseHandle(process.hThread);
  for (int i = 0; i < 3; ++i)
    if (handles[i] != INVALID_HANDLE_VALUE) CloseHandle(handles[i]);
  if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
  free(attributes);
  free(environment);
  if (error != ERROR_SUCCESS) return titan_winfs_error(L, "launch compiler", error);
  lua_pushboolean(L, 1);
  return 1;
}

static int titan_winprocess_wait(lua_State *L) {
  titan_winprocess_batch *batch = (titan_winprocess_batch *)
      luaL_checkudata(L, 1, TITAN_WINPROCESS_MT);
  DWORD index, error;
  ULONG_PTR key;
  LPOVERLAPPED overlapped;
  if (batch->port == NULL || batch->children == NULL)
    return titan_winfs_error(L, "wait compiler", ERROR_INVALID_HANDLE);
  for (;;) {
    if (GetQueuedCompletionStatus(batch->port, &index, &key, &overlapped, 1000)) {
      lua_pushinteger(L, (lua_Integer)index);
      return 1;
    }
    error = GetLastError();
    if (error != WAIT_TIMEOUT) return titan_winfs_error(L, "wait compiler", error);
    error = (DWORD)InterlockedCompareExchange(&batch->completion_error, 0, 0);
    if (error != ERROR_SUCCESS) return titan_winfs_error(L, "notify compiler", error);
  }
}

static int titan_winprocess_finish(lua_State *L) {
  titan_winprocess_batch *batch = (titan_winprocess_batch *)
      luaL_checkudata(L, 1, TITAN_WINPROCESS_MT);
  lua_Integer index = luaL_checkinteger(L, 2);
  titan_winprocess_child **link = &batch->children, *child;
  DWORD status, error = ERROR_SUCCESS;
  while (*link != NULL && (*link)->index != (lua_Unsigned)index)
    link = &(*link)->next;
  if (*link == NULL) return titan_winfs_error(L, "reap compiler", ERROR_INVALID_HANDLE);
  child = *link;
  if (WaitForSingleObject(child->process, INFINITE) == WAIT_FAILED ||
      !GetExitCodeProcess(child->process, &status)) error = GetLastError();
  *link = child->next;
  titan_winprocess_release(child);
  if (error != ERROR_SUCCESS) return titan_winfs_error(L, "reap compiler", error);
  if (status == 0) lua_pushboolean(L, 1); else lua_pushnil(L);
  lua_pushliteral(L, "exit");
  lua_pushinteger(L, (lua_Integer)status);
  return 3;
}

static int titan_winprocess_close(lua_State *L) {
  titan_winprocess_batch *batch = (titan_winprocess_batch *)
      luaL_checkudata(L, 1, TITAN_WINPROCESS_MT);
  DWORD error = titan_winprocess_close_batch(batch);
  if (error != ERROR_SUCCESS) return titan_winfs_error(L, "close compiler batch", error);
  lua_pushboolean(L, 1);
  return 1;
}

#endif
