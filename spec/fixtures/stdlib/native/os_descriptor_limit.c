#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
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

int titan_test_open_fd_count(void) {
    DWORD count;
    return GetProcessHandleCount(GetCurrentProcess(), &count) ? (int)count : -1;
}

int titan_test_tcp_stdio_pair(int ipv6, int *accepted_fd, int *peer_fd) {
    (void)ipv6;
    if (accepted_fd != NULL) *accepted_fd = -1;
    if (peer_fd != NULL) *peer_fd = -1;
    return ENOSYS;
}

int titan_test_tcp_stdio_install_fd(int source_fd, int target_fd) {
    (void)source_fd;
    (void)target_fd;
    return -1;
}

int titan_test_tcp_stdio_close_fd(int fd) {
    (void)fd;
    return -1;
}

int titan_test_tcp_stdio_reset_close(int fd) {
    (void)fd;
    return -1;
}

int titan_test_tcp_stdio_bound_buffers(int accepted_fd, int peer_fd, int bytes) {
    (void)accepted_fd;
    (void)peer_fd;
    (void)bytes;
    return -1;
}

int titan_test_tcp_stdio_spawn_child(
    const char *program, const char *mode, const char *arg1, const char *arg2,
    int ipv6, int alias_stderr, int *peer_fd_out, int *child_pid_out) {
    (void)program;
    (void)mode;
    (void)arg1;
    (void)arg2;
    (void)ipv6;
    (void)alias_stderr;
    if (peer_fd_out != NULL) *peer_fd_out = -1;
    if (child_pid_out != NULL) *child_pid_out = -1;
    return ENOSYS;
}

int titan_test_tcp_stdio_wait_child(int child_pid, int *exit_code_out) {
    (void)child_pid;
    if (exit_code_out != NULL) *exit_code_out = -1;
    return ENOSYS;
}
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
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

int titan_test_open_fd_count(void) {
    struct rlimit limit;
    rlim_t maximum;
    int descriptor;
    int count = 0;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0)
        return -1;
    maximum = limit.rlim_cur;
    if (maximum == RLIM_INFINITY || maximum > 65536)
        maximum = 65536;
    for (descriptor = 0; (rlim_t)descriptor < maximum; descriptor++) {
        errno = 0;
        if (fcntl(descriptor, F_GETFD) >= 0 || errno != EBADF)
            count++;
    }
    return count;
}

int titan_test_tcp_stdio_pair(int ipv6, int *accepted_fd, int *peer_fd) {
    int listener = -1;
    int client = -1;
    int accepted = -1;
    int saved_errno = EIO;
    if (accepted_fd != NULL) *accepted_fd = -1;
    if (peer_fd != NULL) *peer_fd = -1;
    if (accepted_fd == NULL || peer_fd == NULL) return EINVAL;

    if (ipv6 != 0) {
        struct sockaddr_in6 addr6;
        socklen_t len6 = sizeof(addr6);
        listener = socket(AF_INET6, SOCK_STREAM, 0);
        if (listener < 0) {
            return (errno == EAFNOSUPPORT || errno == EADDRNOTAVAIL) ? -2 : errno;
        }
        memset(&addr6, 0, sizeof(addr6));
        addr6.sin6_family = AF_INET6;
        addr6.sin6_port = 0;
        if (inet_pton(AF_INET6, "::1", &addr6.sin6_addr) != 1 ||
            bind(listener, (struct sockaddr *)&addr6, sizeof(addr6)) != 0) {
            saved_errno = (errno == EAFNOSUPPORT || errno == EADDRNOTAVAIL) ? -2 : errno;
            goto fail;
        }
        if (listen(listener, 1) != 0 ||
            getsockname(listener, (struct sockaddr *)&addr6, &len6) != 0) {
            saved_errno = errno;
            goto fail;
        }
        client = socket(AF_INET6, SOCK_STREAM, 0);
        if (client < 0 ||
            connect(client, (struct sockaddr *)&addr6, len6) != 0) {
            saved_errno = errno;
            goto fail;
        }
    } else {
        struct sockaddr_in addr4;
        socklen_t len4 = sizeof(addr4);
        listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0) return errno;
        memset(&addr4, 0, sizeof(addr4));
        addr4.sin_family = AF_INET;
        addr4.sin_port = 0;
        if (inet_pton(AF_INET, "127.0.0.1", &addr4.sin_addr) != 1 ||
            bind(listener, (struct sockaddr *)&addr4, sizeof(addr4)) != 0 ||
            listen(listener, 1) != 0 ||
            getsockname(listener, (struct sockaddr *)&addr4, &len4) != 0) {
            saved_errno = errno;
            goto fail;
        }
        client = socket(AF_INET, SOCK_STREAM, 0);
        if (client < 0 ||
            connect(client, (struct sockaddr *)&addr4, len4) != 0) {
            saved_errno = errno;
            goto fail;
        }
    }
    do {
        accepted = accept(listener, NULL, NULL);
    } while (accepted < 0 && errno == EINTR);
    if (accepted < 0) {
        saved_errno = errno;
        goto fail;
    }
    close(listener);
    listener = -1;
    if (fcntl(accepted, F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(client, F_SETFD, FD_CLOEXEC) != 0) {
        saved_errno = errno;
        goto fail;
    }
    *accepted_fd = accepted;
    *peer_fd = client;
    return 0;

fail:
    if (listener >= 0) close(listener);
    if (client >= 0) close(client);
    if (accepted >= 0) close(accepted);
    return saved_errno != 0 ? saved_errno : EIO;
}

int titan_test_tcp_stdio_install_fd(int source_fd, int target_fd) {
    int result;
    if (source_fd < 0 || target_fd < 0 || target_fd > 2) return -1;
    do {
        result = dup2(source_fd, target_fd);
    } while (result < 0 && errno == EINTR);
    return result < 0 ? -1 : 0;
}

int titan_test_tcp_stdio_close_fd(int fd) {
    if (fd < 0) return 0;
    return close(fd) == 0 ? 0 : -1;
}

int titan_test_tcp_stdio_reset_close(int fd) {
    struct linger sl;
    if (fd < 0) return -1;
    sl.l_onoff = 1;
    sl.l_linger = 0;
    (void)setsockopt(fd, SOL_SOCKET, SO_LINGER, &sl, sizeof(sl));
    (void)close(fd);
    return 0;
}

int titan_test_tcp_stdio_bound_buffers(int accepted_fd, int peer_fd, int bytes) {
    int snd = bytes;
    int rcv = bytes;
    if (accepted_fd < 0 || peer_fd < 0 || bytes <= 0) return -1;
    if (setsockopt(accepted_fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd)) != 0 ||
        setsockopt(peer_fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv)) != 0) {
        return -1;
    }
    return 0;
}

int titan_test_tcp_stdio_spawn_child(
    const char *program, const char *mode, const char *arg1, const char *arg2,
    int ipv6, int alias_stderr, int *peer_fd_out, int *child_pid_out) {
    int accepted_fd = -1;
    int peer_fd = -1;
    int status;
    pid_t pid;
    if (peer_fd_out != NULL) *peer_fd_out = -1;
    if (child_pid_out != NULL) *child_pid_out = -1;
    if (program == NULL || mode == NULL || arg1 == NULL || arg2 == NULL ||
        peer_fd_out == NULL || child_pid_out == NULL) {
        return EINVAL;
    }
    status = titan_test_tcp_stdio_pair(ipv6, &accepted_fd, &peer_fd);
    if (status != 0) return status;
    fflush(NULL);
    pid = fork();
    if (pid < 0) {
        int saved_errno = errno;
        close(accepted_fd);
        close(peer_fd);
        return saved_errno != 0 ? saved_errno : EIO;
    }
    if (pid == 0) {
        close(peer_fd);
        while (dup2(accepted_fd, 0) < 0 && errno == EINTR) {}
        while (dup2(accepted_fd, 1) < 0 && errno == EINTR) {}
        if (alias_stderr != 0) {
            while (dup2(accepted_fd, 2) < 0 && errno == EINTR) {}
        }
        if (accepted_fd > 2) close(accepted_fd);
        execl(program, program, mode, arg1, arg2, (char *)NULL);
        _exit(127);
    }
    close(accepted_fd);
    *peer_fd_out = peer_fd;
    *child_pid_out = (int)pid;
    return 0;
}

int titan_test_tcp_stdio_wait_child(int child_pid, int *exit_code_out) {
    int status = 0;
    pid_t waited;
    if (exit_code_out == NULL || child_pid <= 0) return EINVAL;
    *exit_code_out = -1;
    do {
        waited = waitpid((pid_t)child_pid, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited < 0) return errno;
    if (WIFEXITED(status)) {
        *exit_code_out = WEXITSTATUS(status);
        return 0;
    }
    if (WIFSIGNALED(status)) {
        *exit_code_out = 128 + WTERMSIG(status);
        return 0;
    }
    return 0;
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
