#ifndef TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
#define TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
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
int titan_test_worker_gate_finished(void *raw);
void titan_test_worker_gate_fail(void *raw);
int titan_test_worker_gate_failed(void *raw);

int titan_test_fd_is_open(int fd);
int titan_test_open_file_onto_fd(const char *path, int mode, int target_fd);
int titan_test_dup_fd(int fd);
int titan_test_restore_fd(int saved_fd, int target_fd);
int titan_test_rewind_fd(int fd);
#endif
