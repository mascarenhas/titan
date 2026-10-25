#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "os_descriptor_limit.h"

void titan_test_worker_gate_init(void *raw) {
    int *cells = raw;
    __atomic_store_n(&cells[0], 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&cells[1], 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&cells[2], 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&cells[3], 0, __ATOMIC_SEQ_CST);
}

void titan_test_worker_gate_noop(void *raw) {
    (void)raw;
}

int titan_test_worker_gate_entered(void *raw) {
    int *cells = raw;
    return __atomic_load_n(&cells[0], __ATOMIC_ACQUIRE);
}

void titan_test_worker_gate_release(void *raw) {
    int *cells = raw;
    __atomic_store_n(&cells[1], 1, __ATOMIC_RELEASE);
}

int titan_test_worker_gate_is_released(void *raw) {
    int *cells = raw;
    return __atomic_load_n(&cells[1], __ATOMIC_ACQUIRE);
}

int titan_test_worker_gate_finished(void *raw) {
    int *cells = raw;
    return __atomic_load_n(&cells[2], __ATOMIC_ACQUIRE);
}

void titan_test_worker_gate_fail(void *raw) {
    int *cells = raw;
    __atomic_store_n(&cells[3], 1, __ATOMIC_RELEASE);
}

int titan_test_worker_gate_failed(void *raw) {
    int *cells = raw;
    return __atomic_load_n(&cells[3], __ATOMIC_ACQUIRE);
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>

static const DWORD standard_kinds[3] = {
    STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
};

void titan_test_worker_gate_work(void *raw) {
    int *cells = raw;
    __atomic_add_fetch(&cells[0], 1, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&cells[1], __ATOMIC_ACQUIRE) == 0) {
        Sleep(1);
    }
    __atomic_add_fetch(&cells[2], 1, __ATOMIC_ACQ_REL);
}

int titan_test_fd_limit_lower(void) { return ENOSYS; }
int titan_test_fd_limit_restore(void) { return ENOSYS; }
int titan_test_fd_limit_restored(void) { return 0; }

int titan_test_fsize_limit_supported(void) { return 0; }
int titan_test_fsize_limit_efbig(long limit) { (void)limit; return ENOSYS; }
int titan_test_fsize_limit_short_write_once(long limit) { (void)limit; return ENOSYS; }
int titan_test_fsize_limit_restore(void) { return 0; }
int titan_test_fsize_sigxfsz_count(void) { return 0; }

int titan_test_fd_is_open(int fd) {
    intptr_t osf;
    DWORD flags;
    if (fd < 0) return 0;
    osf = _get_osfhandle(fd);
    if (osf == -1) return 0;
    return GetHandleInformation((HANDLE)osf, &flags) ? 1 : 0;
}

int titan_test_open_file_onto_fd(const char *path, int mode, int target_fd) {
    int wide_len;
    wchar_t *wide_path;
    DWORD access = GENERIC_READ;
    DWORD creation = OPEN_EXISTING;
    int crt_flags = _O_RDONLY | _O_BINARY;
    HANDLE handle;
    int fd;
    if (path == NULL || target_fd < 0 || target_fd > 2) return -1;
    if (mode == 1) {
        access = GENERIC_WRITE;
        creation = CREATE_ALWAYS;
        crt_flags = _O_WRONLY | _O_BINARY;
    } else if (mode == 2) {
        access = FILE_APPEND_DATA | SYNCHRONIZE;
        creation = OPEN_ALWAYS;
        crt_flags = _O_WRONLY | _O_APPEND | _O_BINARY;
    } else if (mode == 3) {
        access = GENERIC_READ | GENERIC_WRITE;
        creation = CREATE_ALWAYS;
        crt_flags = _O_RDWR | _O_BINARY;
    }
    wide_len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (wide_len <= 0) return -1;
    wide_path = malloc((size_t)wide_len * sizeof(wchar_t));
    if (wide_path == NULL) return -1;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide_path, wide_len)) {
        free(wide_path);
        return -1;
    }
    handle = CreateFileW(wide_path, access,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, creation, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide_path);
    if (handle == INVALID_HANDLE_VALUE) return -1;
    fd = _open_osfhandle((intptr_t)handle, crt_flags);
    if (fd < 0) {
        CloseHandle(handle);
        return -1;
    }
    if (_dup2(fd, target_fd) != 0) {
        _close(fd);
        return -1;
    }
    _close(fd);
    if (!SetStdHandle(standard_kinds[target_fd], (HANDLE)_get_osfhandle(target_fd))) {
        return -1;
    }
    return 0;
}

int titan_test_dup_fd(int fd) {
    int saved = _dup(fd);
    if (saved >= 0) {
        (void)SetHandleInformation((HANDLE)_get_osfhandle(saved), HANDLE_FLAG_INHERIT, 0);
    }
    return saved;
}

int titan_test_restore_fd(int saved_fd, int target_fd) {
    if (saved_fd < 0 || target_fd < 0 || target_fd > 2) return -1;
    if (_dup2(saved_fd, target_fd) != 0) return -1;
    _close(saved_fd);
    if (!SetStdHandle(standard_kinds[target_fd], (HANDLE)_get_osfhandle(target_fd))) {
        return -1;
    }
    return 0;
}

int titan_test_rewind_fd(int fd) {
    return _lseeki64(fd, 0, SEEK_SET) == 0 ? 0 : -1;
}
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static struct rlimit saved;
static int active;

static struct rlimit saved_fsize;
static struct sigaction saved_sigxfsz;
static int fsize_active;
static volatile sig_atomic_t sigxfsz_count;

void titan_test_worker_gate_work(void *raw) {
    int *cells = raw;
    struct timespec pause;
    pause.tv_sec = 0;
    pause.tv_nsec = 1000000L;
    __atomic_add_fetch(&cells[0], 1, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&cells[1], __ATOMIC_ACQUIRE) == 0) {
        nanosleep(&pause, NULL);
    }
    __atomic_add_fetch(&cells[2], 1, __ATOMIC_ACQ_REL);
}

int titan_test_fd_limit_lower(void) {
    struct rlimit limited;
    if (active) return EBUSY;
    if (getrlimit(RLIMIT_NOFILE, &saved) != 0) return errno;
    limited = saved;
    limited.rlim_cur = 0;
    if (setrlimit(RLIMIT_NOFILE, &limited) != 0) return errno;
    active = 1;
    return 0;
}

int titan_test_fd_limit_restore(void) {
    if (!active) return 0;
    if (setrlimit(RLIMIT_NOFILE, &saved) != 0) return errno;
    active = 0;
    return 0;
}

int titan_test_fd_limit_restored(void) {
    struct rlimit current;
    return !active && getrlimit(RLIMIT_NOFILE, &current) == 0 &&
           current.rlim_cur == saved.rlim_cur && current.rlim_max == saved.rlim_max;
}

static void handle_sigxfsz_restore(int signum) {
    int saved_errno = errno;
    (void)signum;
    __atomic_add_fetch(&sigxfsz_count, 1, __ATOMIC_RELAXED);
    (void)setrlimit(RLIMIT_FSIZE, &saved_fsize);
    errno = saved_errno;
}

int titan_test_fsize_limit_supported(void) {
    return 1;
}

int titan_test_fsize_limit_efbig(long limit) {
    struct rlimit limited;
    struct sigaction action;
    if (fsize_active) return EBUSY;
    if (limit <= 0) return EINVAL;
    if (getrlimit(RLIMIT_FSIZE, &saved_fsize) != 0) return errno;
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGXFSZ, &action, &saved_sigxfsz) != 0) return errno;
    limited = saved_fsize;
    limited.rlim_cur = (rlim_t)limit;
    if (setrlimit(RLIMIT_FSIZE, &limited) != 0) {
        int err = errno;
        (void)sigaction(SIGXFSZ, &saved_sigxfsz, NULL);
        return err;
    }
    __atomic_store_n(&sigxfsz_count, 0, __ATOMIC_RELEASE);
    fsize_active = 1;
    return 0;
}

int titan_test_fsize_limit_short_write_once(long limit) {
    struct rlimit limited;
    struct sigaction action;
    if (fsize_active) return EBUSY;
    if (limit <= 0) return EINVAL;
    if (getrlimit(RLIMIT_FSIZE, &saved_fsize) != 0) return errno;
    action.sa_handler = handle_sigxfsz_restore;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGXFSZ, &action, &saved_sigxfsz) != 0) return errno;
    limited = saved_fsize;
    limited.rlim_cur = (rlim_t)limit;
    if (setrlimit(RLIMIT_FSIZE, &limited) != 0) {
        int err = errno;
        (void)sigaction(SIGXFSZ, &saved_sigxfsz, NULL);
        return err;
    }
    __atomic_store_n(&sigxfsz_count, 0, __ATOMIC_RELEASE);
    fsize_active = 1;
    return 0;
}

int titan_test_fsize_limit_restore(void) {
    int err = 0;
    if (!fsize_active) return 0;
    if (setrlimit(RLIMIT_FSIZE, &saved_fsize) != 0) err = errno;
    if (sigaction(SIGXFSZ, &saved_sigxfsz, NULL) != 0 && err == 0) err = errno;
    fsize_active = 0;
    return err;
}

int titan_test_fsize_sigxfsz_count(void) {
    return (int)__atomic_load_n(&sigxfsz_count, __ATOMIC_ACQUIRE);
}

int titan_test_fd_is_open(int fd) {
    return fd >= 0 && fcntl(fd, F_GETFD) >= 0 ? 1 : 0;
}

int titan_test_open_file_onto_fd(const char *path, int mode, int target_fd) {
    int flags = O_RDONLY;
    int fd;
    int result;
    if (path == NULL || target_fd < 0 || target_fd > 2) return -1;
    if (mode == 1) flags = O_WRONLY | O_CREAT | O_TRUNC;
    else if (mode == 2) flags = O_WRONLY | O_CREAT | O_APPEND;
    else if (mode == 3) flags = O_RDWR | O_CREAT | O_TRUNC;
    do {
        fd = open(path, flags, 0600);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;
    if (fd != target_fd) {
        do {
            result = dup2(fd, target_fd);
        } while (result < 0 && errno == EINTR);
        close(fd);
        if (result < 0) return -1;
    }
    return 0;
}

int titan_test_dup_fd(int fd) {
    int saved = dup(fd);
    if (saved >= 0) {
        int flags = fcntl(saved, F_GETFD);
        if (flags >= 0) (void)fcntl(saved, F_SETFD, flags | FD_CLOEXEC);
    }
    return saved;
}

int titan_test_restore_fd(int saved_fd, int target_fd) {
    int result;
    if (saved_fd < 0 || target_fd < 0 || target_fd > 2) return -1;
    do {
        result = dup2(saved_fd, target_fd);
    } while (result < 0 && errno == EINTR);
    close(saved_fd);
    return result < 0 ? -1 : 0;
}

int titan_test_rewind_fd(int fd) {
    return lseek(fd, 0, SEEK_SET) == 0 ? 0 : -1;
}
#endif

static titan_test_alloc_fn saved_alloc;
static void *saved_alloc_data;
static size_t watched_userdata_tag;
static size_t watched_userdata_size;
static int slice_fault_watching;
static int slice_fault_armed;
static int slice_fault_hits;
static int slice_fault_budget;

void *titan_test_slice_fault_alloc(void *data, void *pointer, size_t old_size, size_t new_size) {
    (void)data;
    if (slice_fault_watching && pointer == NULL && old_size == watched_userdata_tag) {
        watched_userdata_size = new_size;
    }
    if (slice_fault_armed && titan_test_fsize_sigxfsz_count() > 0 &&
        pointer == NULL && old_size == watched_userdata_tag &&
        (slice_fault_hits >= 2 || new_size == watched_userdata_size)) {
        slice_fault_hits = slice_fault_hits + 1;
        if (slice_fault_hits >= slice_fault_budget) {
            slice_fault_armed = 0;
        }
        return NULL;
    }
    return saved_alloc(saved_alloc_data, pointer, old_size, new_size);
}

void titan_test_slice_fault_configure(titan_test_alloc_fn prev, void *prev_data, size_t userdata_tag) {
    saved_alloc = prev;
    saved_alloc_data = prev_data;
    watched_userdata_tag = userdata_tag;
    watched_userdata_size = 0;
    slice_fault_watching = 1;
    slice_fault_armed = 0;
    slice_fault_hits = 0;
}

void titan_test_slice_fault_watch_end(void) {
    slice_fault_watching = 0;
}

void titan_test_slice_fault_arm(int budget) {
    slice_fault_budget = budget;
    slice_fault_armed = 1;
}

void titan_test_slice_fault_disarm(void) {
    slice_fault_watching = 0;
    slice_fault_armed = 0;
}

int titan_test_slice_fault_hits(void) {
    return slice_fault_hits;
}

int titan_test_slice_fault_size(void) {
    return (int)watched_userdata_size;
}
