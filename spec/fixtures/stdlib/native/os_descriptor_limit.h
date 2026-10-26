#ifndef TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
#define TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
#include <stddef.h>

int titan_test_fd_limit_lower(void);
int titan_test_fd_limit_restore(void);
int titan_test_fd_limit_restored(void);

int titan_test_fsize_limit_supported(void);
int titan_test_fsize_limit_efbig(long limit);
int titan_test_fsize_limit_short_write_once(long limit);
int titan_test_fsize_limit_restore(void);
int titan_test_fsize_sigxfsz_count(void);

void titan_test_worker_gate_init(void *raw);
void titan_test_worker_gate_work(void *raw);
void titan_test_worker_gate_noop(void *raw);
int titan_test_worker_gate_entered(void *raw);
void titan_test_worker_gate_release(void *raw);
int titan_test_worker_gate_is_released(void *raw);
int titan_test_worker_gate_finished(void *raw);
void titan_test_worker_gate_fail(void *raw);
int titan_test_worker_gate_failed(void *raw);

int titan_test_fd_is_open(int fd);
int titan_test_open_file_onto_fd(const char *path, int mode, int target_fd);
int titan_test_dup_fd(int fd);
int titan_test_restore_fd(int saved_fd, int target_fd);
int titan_test_rewind_fd(int fd);
int titan_test_open_fd_count(void);

int titan_test_tcp_stdio_pair(int ipv6, int *accepted_fd, int *peer_fd);
int titan_test_tcp_stdio_install_fd(int source_fd, int target_fd);
int titan_test_tcp_stdio_close_fd(int fd);
int titan_test_tcp_stdio_reset_close(int fd);
int titan_test_tcp_stdio_spawn_child(
    const char *program, const char *mode, const char *arg1, const char *arg2,
    int ipv6, int alias_stderr, int *peer_fd_out, int *child_pid_out);
int titan_test_tcp_stdio_wait_child(int child_pid, int *exit_code_out);

typedef void *(*titan_test_alloc_fn)(void *data, void *pointer, size_t old_size, size_t new_size);
void *titan_test_slice_fault_alloc(void *data, void *pointer, size_t old_size, size_t new_size);
void titan_test_slice_fault_configure(titan_test_alloc_fn prev, void *prev_data, size_t userdata_tag);
void titan_test_slice_fault_watch_end(void);
void titan_test_slice_fault_arm(int budget);
void titan_test_slice_fault_disarm(void);
int titan_test_slice_fault_hits(void);
int titan_test_slice_fault_size(void);
#endif
