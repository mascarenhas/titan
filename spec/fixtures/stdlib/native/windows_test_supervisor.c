/* Windows 11 test harness only. The child enters our private job atomically at
 * creation; an owner crash at any later point closes the job and kills its tree.
 * No PID enumeration, global job, shell, or production process bridge is used. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0a00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#define COMMAND_CAPACITY 32767
#define FAILURE 125

static void report(const char *operation) {
    fprintf(stderr, "Windows test supervisor: %s failed (error %lu).\n",
            operation, (unsigned long)GetLastError());
}

/* Microsoft CRT argv quoting, including empty arguments and terminal slashes. */
static int append(wchar_t *command, size_t *length, wchar_t c) {
    if (*length >= COMMAND_CAPACITY - 1) return 0;
    command[(*length)++] = c;
    return 1;
}
static int quote(wchar_t *command, size_t *length, const wchar_t *arg) {
    if (!append(command, length, L'"')) return 0;
    for (;;) {
        size_t slashes = 0;
        while (*arg == L'\\') { ++slashes; ++arg; }
        size_t count = slashes;
        if (*arg == L'"' || !*arg) count *= 2;
        while (count--) if (!append(command, length, L'\\')) return 0;
        if (!*arg) return append(command, length, L'"');
        if (*arg == L'"' && !append(command, length, L'\\')) return 0;
        if (!append(command, length, *arg++)) return 0;
    }
}

static HANDLE standard_handle(DWORD kind, DWORD access) {
    HANDLE source = GetStdHandle(kind), result = NULL;
    if (source && source != INVALID_HANDLE_VALUE) {
        if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                             &result, 0, TRUE, DUPLICATE_SAME_ACCESS)) return NULL;
    } else {
        SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
        result = CreateFileW(L"NUL", access, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &security, OPEN_EXISTING, 0, NULL);
        if (result == INVALID_HANDLE_VALUE) return NULL;
    }
    return result;
}

static int stop_job(HANDLE job) {
    if (!TerminateJobObject(job, FAILURE)) { report("TerminateJobObject"); return 0; }
    ULONGLONG limit = GetTickCount64() + 10000;
    for (;;) {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
        if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                       &accounting, sizeof(accounting), NULL)) {
            report("QueryInformationJobObject"); return 0;
        }
        if (!accounting.ActiveProcesses) return 1;
        if (GetTickCount64() >= limit) {
            fputs("Windows test supervisor: owned job did not empty.\n", stderr);
            return 0;
        }
        Sleep(10);
    }
}

int wmain(int argc, wchar_t **argv) {
    wchar_t *end = NULL;
    errno = 0;
    unsigned long timeout = argc >= 2 ? wcstoul(argv[1], &end, 10) : 0;
    if (argc < 3 || !argv[1][0] || !end || *end || errno || !timeout ||
        argv[1][0] == L'-' || timeout >= INFINITE) {
        fputs("usage: windows-test-supervisor TIMEOUT_MS EXE [ARG...]\n", stderr);
        return FAILURE;
    }
    int result = FAILURE, attributes_ready = 0, child_created = 0;
    HANDLE job = NULL, handles[3] = {NULL, NULL, NULL};
    PROCESS_INFORMATION child = {0};
    STARTUPINFOEXW start = {0};
    wchar_t *command = calloc(COMMAND_CAPACITY, sizeof(*command));
    SIZE_T attribute_bytes = 0;
    if (!command) { fputs("Windows test supervisor: out of memory.\n", stderr); goto done; }
    size_t length = 0;
    for (int i = 2; i < argc; ++i) {
        if ((i > 2 && !append(command, &length, L' ')) || !quote(command, &length, argv[i])) {
            fputs("Windows test supervisor: command line exceeds Windows limit.\n", stderr);
            goto done;
        }
    }
    command[length] = 0;
    job = CreateJobObjectW(NULL, NULL); /* Noninheritable and unnamed. */
    if (!job) { report("CreateJobObjectW"); goto done; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        report("SetInformationJobObject"); goto done;
    }
    handles[0] = standard_handle(STD_INPUT_HANDLE, GENERIC_READ);
    handles[1] = standard_handle(STD_OUTPUT_HANDLE, GENERIC_WRITE);
    handles[2] = standard_handle(STD_ERROR_HANDLE, GENERIC_WRITE);
    if (!handles[0] || !handles[1] || !handles[2]) { report("standard handle duplication"); goto done; }
    InitializeProcThreadAttributeList(NULL, 2, 0, &attribute_bytes);
    if (!attribute_bytes) { report("attribute size"); goto done; }
    start.lpAttributeList = malloc(attribute_bytes);
    if (!start.lpAttributeList) { fputs("Windows test supervisor: out of memory.\n", stderr); goto done; }
    if (!InitializeProcThreadAttributeList(start.lpAttributeList, 2, 0, &attribute_bytes)) {
        report("InitializeProcThreadAttributeList"); goto done;
    }
    attributes_ready = 1;
    if (!UpdateProcThreadAttribute(start.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   &job, sizeof(job), NULL, NULL) ||
        !UpdateProcThreadAttribute(start.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   handles, sizeof(handles), NULL, NULL)) {
        report("UpdateProcThreadAttribute"); goto done;
    }
    start.StartupInfo.cb = sizeof(start);
    start.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    start.StartupInfo.hStdInput = handles[0];
    start.StartupInfo.hStdOutput = handles[1];
    start.StartupInfo.hStdError = handles[2];
    if (!CreateProcessW(argv[2], command, NULL, NULL, TRUE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
                        NULL, NULL, &start.StartupInfo, &child)) {
        report("CreateProcessW (atomic job assignment)"); goto done;
    }
    child_created = 1;
    /* Creation succeeded only with the job attached. Never run an unowned child. */
    if (ResumeThread(child.hThread) == (DWORD)-1) { report("ResumeThread"); goto done; }
    DWORD waited = WaitForSingleObject(child.hProcess, (DWORD)timeout), code;
    if (waited == WAIT_TIMEOUT) {
        fputs("Windows test supervisor: native test deadline exceeded.\n", stderr);
        result = 124;
    } else if (waited == WAIT_OBJECT_0 && GetExitCodeProcess(child.hProcess, &code)) {
        result = (int)code;
    } else { report("wait for child exit"); }

done:
    /* Also reap descendants after an early normal parent exit before pipes drain. */
    if (child_created && !stop_job(job)) result = FAILURE;
    if (child.hThread) CloseHandle(child.hThread);
    if (child.hProcess) CloseHandle(child.hProcess);
    if (attributes_ready) DeleteProcThreadAttributeList(start.lpAttributeList);
    free(start.lpAttributeList);
    for (int i = 0; i < 3; ++i) if (handles[i]) CloseHandle(handles[i]);
    if (job) CloseHandle(job);
    free(command);
    return result;
}
